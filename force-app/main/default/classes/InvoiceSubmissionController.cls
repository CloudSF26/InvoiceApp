public with sharing class InvoiceSubmissionController {
    @TestVisible private static String lastCode;
    private static final String SENDER_ADDRESS = 'no.reply.no.connect@gmail.com';
    private static Id cachedSenderId;

    @TestVisible
    private static Id invoiceSenderId() {
        if (cachedSenderId == null) {
            List<OrgWideEmailAddress> senders = [SELECT Id, IsVerified FROM OrgWideEmailAddress
                WHERE Address = :SENDER_ADDRESS WITH SYSTEM_MODE LIMIT 1];
            if (senders.isEmpty() || !senders[0].IsVerified) {
                throw new AuraHandledException('The invoice email sender is not configured or verified. Contact your site administrator.');
            }
            cachedSenderId = senders[0].Id;
        }
        return cachedSenderId;
    }

    public class VerificationResult {
        @AuraEnabled public Id invoiceId { get; set; }
        @AuraEnabled public String invoiceNumber { get; set; }
        @AuraEnabled public String error { get; set; }
    }

    private static String digest(String value) {
        return EncodingUtil.convertToHex(Crypto.generateDigest('SHA-256', Blob.valueOf(value)));
    }

    private static String payloadHash(String name, String email, List<Invoice_Line_Item__c> lines) {
        return digest(JSON.serialize(new List<String>{ name, email, JSON.serialize(lines) }));
    }

    @AuraEnabled
    public static String requestOtp(String submitterName, String email, List<Invoice_Line_Item__c> lineItems) {
        if (UserInfo.getUserType() == 'Guest') throw new AuraHandledException('Sign in to submit an invoice.');
        if (String.isBlank(submitterName) || String.isBlank(email) || email.length() > 80 ||
            !Pattern.matches('^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$', email.trim()) ||
            lineItems == null || lineItems.isEmpty() || lineItems.size() > 100) {
            throw new AuraHandledException('Enter your name, a valid email, and invoice line items first.');
        }
        Id userId = UserInfo.getUserId();
        new SubmissionThrottle().check(email);
        Datetime hourAgo = System.now().addHours(-1);
        List<Invoice_Verification__c> recent = [SELECT Id, CreatedDate, Consumed__c FROM Invoice_Verification__c
            WHERE CreatedById = :userId AND Expires__c != null AND CreatedDate >= :hourAgo WITH SYSTEM_MODE ORDER BY CreatedDate DESC LIMIT 12];
        if (recent.size() >= 12 || (!recent.isEmpty() && recent[0].CreatedDate > System.now().addSeconds(-60))) {
            throw new AuraHandledException('Wait at least 60 seconds between codes. A maximum of twelve codes may be requested per hour.');
        }
        // A resend replaces earlier codes for this user.
        for (Invoice_Verification__c previous : recent) previous.Consumed__c = true;
        if (!recent.isEmpty()) update as system recent;
        String token = EncodingUtil.convertToHex(Crypto.generateAesKey(256));
        Long randomValue = Long.valueOf(String.valueOf(Crypto.getRandomInteger()));
        String code = String.valueOf(100000 + Math.mod(Math.abs(randomValue), 900000));
        Invoice_Verification__c challenge = new Invoice_Verification__c(
            Token__c = token, Code_Hash__c = digest(token + code),
            Payload_Hash__c = payloadHash(submitterName, email, lineItems),
            Email_Hash__c = digest(email.trim().toLowerCase()),
            Expires__c = System.now().addMinutes(10), Attempts__c = 0
        );
        insert as system challenge;
        Messaging.SingleEmailMessage message = new Messaging.SingleEmailMessage();
        message.setOrgWideEmailAddressId(invoiceSenderId());
        message.setToAddresses(new List<String>{ email.trim() });
        message.setSubject('Your invoice verification code');
        message.setPlainTextBody('Your invoice verification code is ' + code + '. It expires in 10 minutes. If you did not request this code, ignore this email.');
        message.setSaveAsActivity(false);
        Messaging.SendEmailResult[] results = Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ message });
        if (!results[0].isSuccess()) throw new AuraHandledException('Unable to send a verification email. Contact your site administrator.');
        if (Test.isRunningTest()) lastCode = code;
        return token;
    }

    @AuraEnabled
    public static VerificationResult verifyAndSubmit(String submitterName, String email,
        List<Invoice_Line_Item__c> lineItems, String token, String code) {
        VerificationResult result = new VerificationResult();
        Id userId = UserInfo.getUserId();
        if (UserInfo.getUserType() == 'Guest' || String.isBlank(token)) {
            result.error = 'Request an email verification code first.';
            return result;
        }
        // Acquire shared user/email locks before the challenge lock, matching the send path.
        new SubmissionThrottle().check(email);
        List<Invoice_Verification__c> matches = [SELECT Id, Code_Hash__c, Payload_Hash__c, Attempts__c,
            Expires__c, Consumed__c FROM Invoice_Verification__c
            WHERE Token__c = :token AND CreatedById = :userId WITH SYSTEM_MODE LIMIT 1 FOR UPDATE];
        if (matches.isEmpty()) {
            result.error = 'Invalid verification request. Request a new code.';
            return result;
        }
        Invoice_Verification__c challenge = matches[0];
        if (challenge.Consumed__c || challenge.Expires__c <= System.now() || challenge.Attempts__c >= 5 ||
            challenge.Payload_Hash__c != payloadHash(submitterName, email, lineItems)) {
            result.error = 'This code expired, was used, or the invoice changed. Request a new code.';
            return result;
        }
        challenge.Attempts__c++;
        if (String.isBlank(code) || !Pattern.matches('^[0-9]{6}$', code) || challenge.Code_Hash__c != digest(token + code)) {
            update as system challenge;
            // Return rather than throw so the failed-attempt counter is committed.
            result.error = challenge.Attempts__c >= 5 ? 'Too many attempts. Request a new code.' : 'Incorrect verification code. Please try again.';
            return result;
        }
        result.invoiceId = submitInvoice(submitterName, email, lineItems);
        result.invoiceNumber = [SELECT Name FROM Invoice__c WHERE Id = :result.invoiceId WITH SYSTEM_MODE].Name;
        challenge.Consumed__c = true;
        update as system challenge;
        return result;
    }

    // Only this narrow helper bypasses sharing to count submissions across accounts
    // using the same mailbox. It never returns invoice or user records to the caller.
    private without sharing class SubmissionThrottle {
        public void check(String email) {
            checkBatch(new List<Invoice__c>{ new Invoice__c(Email__c = email) });
        }
        public void checkBatch(List<Invoice__c> invoices) {
            if (invoices.isEmpty()) return;
            if (invoices.size() > 6) throw new AuraHandledException('At most six invoices can be submitted per hour.');
            if (UserInfo.getUserType() == 'Guest') throw new AuraHandledException('Sign in to submit an invoice.');
            Id userId = UserInfo.getUserId();
            Map<String, Integer> incomingByEmail = new Map<String, Integer>();
            Set<String> lockKeys = new Set<String>{ 'user-lock:' + userId };
            for (Invoice__c invoice : invoices) {
                if (String.isBlank(invoice.Email__c) || invoice.Email__c.trim().length() > 80) {
                    throw new AuraHandledException('Enter a valid email address.');
                }
                String email = invoice.Email__c.trim().toLowerCase();
                incomingByEmail.put(email, (incomingByEmail.containsKey(email) ? incomingByEmail.get(email) : 0) + 1);
                lockKeys.add(digest('email-lock:' + email));
            }
            List<String> keys = new List<String>(lockKeys);
            keys.sort();
            for (String key : keys) {
                List<Invoice_Verification__c> locks = [SELECT Id FROM Invoice_Verification__c
                    WHERE Token__c = :key WITH SYSTEM_MODE LIMIT 1 FOR UPDATE];
                if (locks.isEmpty()) {
                    try {
                        insert as system new Invoice_Verification__c(Token__c = key, Consumed__c = true);
                    } catch (DmlException e) {
                        throw new AuraHandledException('Another submission is being processed. Please try again shortly.');
                    }
                }
            }
            Datetime hourAgo = System.now().addHours(-1);
            Integer byUser = [SELECT COUNT() FROM Invoice__c
                WHERE CreatedById = :userId AND CreatedDate >= :hourAgo WITH SYSTEM_MODE];
            if (byUser + invoices.size() > 6) {
                throw new AuraHandledException('The hourly invoice submission limit has been reached. Please try again later.');
            }
            Set<String> emails = incomingByEmail.keySet();
            Map<String, Integer> savedByEmail = new Map<String, Integer>();
            for (AggregateResult row : [SELECT Email__c mailbox, COUNT(Id) total FROM Invoice__c
                WHERE Email__c IN :emails AND CreatedDate >= :hourAgo WITH SYSTEM_MODE GROUP BY Email__c]) {
                String email = String.valueOf(row.get('mailbox')).trim().toLowerCase();
                Integer count = Integer.valueOf(String.valueOf(row.get('total')));
                savedByEmail.put(email, (savedByEmail.containsKey(email) ? savedByEmail.get(email) : 0) + count);
            }
            for (String email : emails) {
                Integer saved = savedByEmail.containsKey(email) ? savedByEmail.get(email) : 0;
                if (saved + incomingByEmail.get(email) > 6) {
                    throw new AuraHandledException('The hourly invoice submission limit has been reached. Please try again later.');
                }
            }
        }
    }

    // Apex-only entry point for the before-insert trigger; not remotely callable.
    public static void enforceSubmissionLimits(List<Invoice__c> invoices) {
        new SubmissionThrottle().checkBatch(invoices);
    }

    @TestVisible
    private static Id submitInvoice(String submitterName, String email, List<Invoice_Line_Item__c> lineItems) {
        if (UserInfo.getUserType() == 'Guest') {
            throw new AuraHandledException('Sign in to submit an invoice.');
        }
        if (String.isBlank(submitterName) || submitterName.trim().length() > 100 ||
            String.isBlank(email) || !Pattern.matches('^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$', email.trim()) || email.trim().length() > 80) {
            throw new AuraHandledException('Enter a valid name and email address.');
        }
        if (lineItems == null || lineItems.isEmpty() || lineItems.size() > 100) {
            throw new AuraHandledException('Include between 1 and 100 line items.');
        }
        Set<String> paymentTerms = new Set<String>();
        for (Schema.PicklistEntry entry : Invoice_Line_Item__c.Payment_Terms__c.getDescribe().getPicklistValues()) {
            if (entry.isActive()) paymentTerms.add(entry.getValue());
        }
        List<Invoice_Line_Item__c> items = new List<Invoice_Line_Item__c>();
        for (Invoice_Line_Item__c source : lineItems) {
            if (source == null || String.isBlank(source.Description_of_Work__c) ||
                source.Description_of_Work__c.length() > 255 || !paymentTerms.contains(source.Payment_Terms__c) ||
                String.isBlank(source.Unit9s__c) || source.Unit9s__c.length() > 4 ||
                source.Contracted_Rate__c == null || source.Contracted_Rate__c < 0 ||
                source.Contracted_Rate__c > 999999.99 || source.Contracted_Rate__c.scale() > 2) {
                throw new AuraHandledException('Check the description, payment terms, units, and rate on every line.');
            }
            Decimal units;
            try {
                units = Decimal.valueOf(source.Unit9s__c);
            } catch (Exception e) {
                throw new AuraHandledException('Units must be a positive number.');
            }
            if (units <= 0) throw new AuraHandledException('Units must be a positive number.');
            Decimal subtotal = (units * source.Contracted_Rate__c).setScale(2);
            if (subtotal > 9999999999.99) throw new AuraHandledException('A line subtotal exceeds the supported amount.');
            items.add(new Invoice_Line_Item__c(
                Description_of_Work__c = source.Description_of_Work__c.trim(),
                Payment_Terms__c = source.Payment_Terms__c,
                Unit9s__c = source.Unit9s__c,
                Contracted_Rate__c = source.Contracted_Rate__c,
                SubTotal__c = subtotal
            ));
        }
        Savepoint checkpoint = Database.setSavepoint();
        try {
            Invoice__c invoice = new Invoice__c(Name__c = submitterName.trim(), Email__c = email.trim(), Status__c = 'Pending');
            insert as user invoice;
            for (Invoice_Line_Item__c item : items) item.Related_Invoice__c = invoice.Id;
            insert as user items;
            // Read only the invoice just created; members need no additional read permissions for the receipt.
            Invoice__c saved = [SELECT Name, Name__c, Email__c, Invoice_Total__c
                FROM Invoice__c WHERE Id = :invoice.Id WITH SYSTEM_MODE];
            Messaging.SingleEmailMessage receipt = new Messaging.SingleEmailMessage();
            receipt.setOrgWideEmailAddressId(invoiceSenderId());
            receipt.setToAddresses(new List<String>{ saved.Email__c });
            receipt.setSubject('Invoice submitted: ' + saved.Name);
            receipt.setHtmlBody(confirmationHtml(saved, items));
            receipt.setPlainTextBody(confirmationText(saved, items));
            receipt.setSaveAsActivity(false);
            Messaging.SendEmailResult[] sent = Messaging.sendEmail(new List<Messaging.SingleEmailMessage>{ receipt });
            if (!sent[0].isSuccess()) throw new AuraHandledException('Unable to send the invoice confirmation.');
            return invoice.Id;
        } catch (Exception e) {
            Database.rollback(checkpoint);
            throw new AuraHandledException('Unable to submit the invoice. Check your access or contact your site administrator.');
        }
    }

    private static String money(Decimal amount) {
        return '$' + String.valueOf((amount == null ? Decimal.valueOf('0') : amount).setScale(2));
    }

    @TestVisible
    private static String confirmationHtml(Invoice__c invoice, List<Invoice_Line_Item__c> items) {
        String html = '<html><body><h2>Invoice submitted successfully.</h2>' +
            '<p><strong>Invoice Number:</strong> ' + invoice.Name.escapeHtml4() +
            '<br/><strong>Submitted Name:</strong> ' + invoice.Name__c.escapeHtml4() +
            '<br/><strong>Invoice Total:</strong> ' + money(invoice.Invoice_Total__c) + '</p>' +
            '<table border="1" cellpadding="8" cellspacing="0" style="border-collapse:collapse;width:100%">' +
            '<caption>Invoice Line Items</caption><thead><tr>' +
            '<th scope="col">Description of Work</th><th scope="col">Payment Terms</th>' +
            '<th scope="col">Contracted Rate</th><th scope="col">Units</th><th scope="col">Subtotal</th>' +
            '</tr></thead><tbody>';
        for (Invoice_Line_Item__c item : items) {
            html += '<tr><td style="white-space:pre-wrap">' + item.Description_of_Work__c.escapeHtml4() +
                '</td><td>' + item.Payment_Terms__c.escapeHtml4() +
                '</td><td>' + money(item.Contracted_Rate__c) +
                '</td><td>' + item.Unit9s__c.escapeHtml4() +
                '</td><td>' + money(item.SubTotal__c) + '</td></tr>';
        }
        return html + '</tbody></table></body></html>';
    }

    private static String confirmationText(Invoice__c invoice, List<Invoice_Line_Item__c> items) {
        String body = 'Invoice submitted successfully.\nInvoice Number: ' + invoice.Name +
            '\nSubmitted Name: ' + invoice.Name__c + '\nInvoice Total: ' + money(invoice.Invoice_Total__c) + '\n\nInvoice Line Items:\n';
        for (Invoice_Line_Item__c item : items) {
            body += '\nDescription of Work: ' + item.Description_of_Work__c + '\nPayment Terms: ' + item.Payment_Terms__c +
                '\nContracted Rate: ' + money(item.Contracted_Rate__c) + '\nUnits: ' + item.Unit9s__c +
                '\nSubtotal: ' + money(item.SubTotal__c) + '\n';
        }
        return body;
    }
}
