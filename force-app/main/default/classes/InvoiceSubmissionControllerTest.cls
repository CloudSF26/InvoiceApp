@IsTest
private class InvoiceSubmissionControllerTest {
    @IsTest static void invoiceStatusesAreRestrictedAndDefaultToPending() {
        Set<String> active = new Set<String>();
        String defaultStatus;
        for (Schema.PicklistEntry entry : Invoice__c.Status__c.getDescribe().getPicklistValues()) {
            if (entry.isActive()) active.add(entry.getValue());
            if (entry.isActive() && entry.isDefaultValue()) defaultStatus = entry.getValue();
        }
        System.assertEquals(new Set<String>{'Pending', 'Rejected', 'Approved'}, active);
        System.assertEquals('Pending', defaultStatus);
        System.assert(Invoice__c.Status__c.getDescribe().isRestrictedPicklist());
        Invoice__c invoice = new Invoice__c(Name__c = 'Default Status', Email__c = 'default@example.com');
        insert as user invoice;
        System.assertEquals('Pending', [SELECT Status__c FROM Invoice__c WHERE Id = :invoice.Id].Status__c);
        Database.SaveResult rejected = Database.insert(new Invoice__c(Name__c = 'Invalid Status',
            Email__c = 'invalid@example.com', Status__c = 'Open'), false, AccessLevel.USER_MODE);
        System.assert(!rejected.isSuccess(), 'Inactive statuses must not be accepted for new invoices.');
    }
    @IsTest static void usesVerifiedInvoiceAdminSender() {
        Id senderId = InvoiceSubmissionController.invoiceSenderId();
        OrgWideEmailAddress sender = [SELECT Address, IsVerified FROM OrgWideEmailAddress
            WHERE Id = :senderId WITH SYSTEM_MODE];
        System.assertEquals('no.reply.no.connect@gmail.com', sender.Address);
        System.assert(sender.IsVerified);
        System.assertEquals(senderId, InvoiceSubmissionController.invoiceSenderId());
    }
    private static Invoice_Line_Item__c item() {
        return new Invoice_Line_Item__c(Description_of_Work__c = 'Consulting',
            Payment_Terms__c = 'Pay per Hour', Unit9s__c = '2.5', Contracted_Rate__c = 12.34,
            SubTotal__c = 1);
    }
    private static List<Invoice__c> seedInvoices(Integer count, String email) {
        List<Invoice__c> invoices = new List<Invoice__c>();
        for (Integer index = 0; index < count; index++) {
            invoices.add(new Invoice__c(Name__c = 'Limit Test', Email__c = email));
        }
        insert as system invoices;
        return invoices;
    }
    @IsTest static void allowsSixthInvoiceAndRejectsSeventhByUser() {
        seedInvoices(5, 'previous@example.com');
        List<Invoice_Line_Item__c> lines = new List<Invoice_Line_Item__c>{ item() };
        String token = InvoiceSubmissionController.requestOtp('Test', 'test@example.com', lines);
        InvoiceSubmissionController.VerificationResult result = InvoiceSubmissionController.verifyAndSubmit(
            'Test', 'test@example.com', lines, token, InvoiceSubmissionController.lastCode);
        System.assertNotEquals(null, result.invoiceId, 'Sixth successful submission must be allowed.');
        Boolean blocked = false;
        try { InvoiceSubmissionController.requestOtp('Test', 'different@example.com', lines); }
        catch (AuraHandledException e) { blocked = true; }
        System.assert(blocked, 'Changing email must not bypass the user limit.');
        System.assertEquals(6, [SELECT COUNT() FROM Invoice__c WITH SYSTEM_MODE]);
    }
    @IsTest static void checksLimitAgainAtVerification() {
        List<Invoice_Line_Item__c> lines = new List<Invoice_Line_Item__c>{ item() };
        String token = InvoiceSubmissionController.requestOtp('Test', 'test@example.com', lines);
        seedInvoices(6, 'previous@example.com');
        Boolean blocked = false;
        try {
            InvoiceSubmissionController.verifyAndSubmit('Test', 'test@example.com', lines, token, InvoiceSubmissionController.lastCode);
        } catch (AuraHandledException e) { blocked = true; }
        System.assert(blocked, 'An earlier OTP must not bypass the submission limit.');
        System.assertEquals(6, [SELECT COUNT() FROM Invoice__c WITH SYSTEM_MODE]);
    }
    @IsTest static void directInsertCannotBypassUserQuota() {
        seedInvoices(6, 'existing@example.com');
        Boolean blocked = false;
        try { insert as system new Invoice__c(Name__c = 'Direct API', Email__c = 'different@example.com'); }
        catch (DmlException e) { blocked = true; }
        System.assert(blocked, 'Direct inserts must be subject to the same quota.');
        System.assertEquals(6, [SELECT COUNT() FROM Invoice__c WITH SYSTEM_MODE]);
    }
    @IsTest static void bulkInsertCannotExceedQuota() {
        Boolean blocked = false;
        try { seedInvoices(7, 'bulk@example.com'); }
        catch (DmlException e) { blocked = true; }
        System.assert(blocked, 'A single API batch must not bypass the limit.');
        System.assertEquals(0, [SELECT COUNT() FROM Invoice__c WITH SYSTEM_MODE]);
    }
    @IsTest static void emailLimitAppliesAcrossUsersAndNormalizesCase() {
        User secondUser = new User(Alias = 'invrate', Email = 'ratetest@example.com',
            EmailEncodingKey = 'UTF-8', LastName = 'Rate Test', LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US', ProfileId = UserInfo.getProfileId(), TimeZoneSidKey = 'America/New_York',
            Username = 'invoice.rate.' + UserInfo.getOrganizationId() + '.' + DateTime.now().getTime() + '@example.com');
        insert secondUser;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            seedInvoices(6, 'shared@example.com');
        }
        System.runAs(secondUser) {
            Boolean blocked = false;
            try {
                InvoiceSubmissionController.requestOtp('Test', ' SHARED@EXAMPLE.COM ', new List<Invoice_Line_Item__c>{ item() });
            } catch (AuraHandledException e) { blocked = true; }
            System.assert(blocked, 'A second account must not bypass the normalized mailbox limit.');
            System.assertEquals(0, [SELECT COUNT() FROM Invoice__c WHERE CreatedById = :secondUser.Id WITH SYSTEM_MODE]);
        }
    }
    @IsTest static void submissionsOlderThanAnHourDoNotCount() {
        List<Invoice__c> invoices = seedInvoices(6, 'old@example.com');
        Test.setCreatedDate(invoices[0].Id, System.now().addMinutes(-61));
        String token = InvoiceSubmissionController.requestOtp('Test', 'test@example.com', new List<Invoice_Line_Item__c>{ item() });
        System.assertNotEquals(null, token);
    }
    @IsTest static void requiresOtpAndPreventsReuse() {
        List<Invoice_Line_Item__c> lines = new List<Invoice_Line_Item__c>{ item() };
        System.assertNotEquals(null, InvoiceSubmissionController.verifyAndSubmit('Test', 'test@example.com', lines, null, null).error);
        String token = InvoiceSubmissionController.requestOtp('Test', 'test@example.com', lines);
        System.assertEquals(0, [SELECT COUNT() FROM Invoice__c]);
        System.assertEquals(1, Limits.getEmailInvocations());
        InvoiceSubmissionController.VerificationResult result = InvoiceSubmissionController.verifyAndSubmit(
            'Test', 'test@example.com', lines, token, InvoiceSubmissionController.lastCode);
        System.assertNotEquals(null, result.invoiceId);
        System.assertEquals([SELECT Name FROM Invoice__c WHERE Id = :result.invoiceId].Name, result.invoiceNumber);
        System.assertEquals(2, Limits.getEmailInvocations(), 'Send OTP followed by one invoice receipt.');
        System.assertNotEquals(null, InvoiceSubmissionController.verifyAndSubmit(
            'Test', 'test@example.com', lines, token, InvoiceSubmissionController.lastCode).error);
        System.assertEquals(1, [SELECT COUNT() FROM Invoice__c]);
    }
    @IsTest static void receiptContainsInvoiceAndEscapedLineItemTable() {
        Invoice__c invoice = new Invoice__c(Name__c = 'Jane <Smith>', Email__c = 'jane@example.com');
        insert as user invoice;
        invoice = [SELECT Name, Name__c, Invoice_Total__c FROM Invoice__c WHERE Id = :invoice.Id];
        Invoice_Line_Item__c line = item();
        line.Description_of_Work__c = '<script>alert(1)</script> & Consulting';
        line.SubTotal__c = 30.85;
        String html = InvoiceSubmissionController.confirmationHtml(invoice, new List<Invoice_Line_Item__c>{ line });
        System.assert(html.contains(invoice.Name));
        System.assert(html.contains('Jane &lt;Smith&gt;'));
        System.assert(html.contains('<table'));
        System.assert(html.contains('Description of Work'));
        System.assert(html.contains('Payment Terms'));
        System.assert(html.contains('Contracted Rate'));
        System.assert(html.contains('Units'));
        System.assert(html.contains('Subtotal'));
        System.assert(html.contains('Pay per Hour'));
        System.assert(html.contains('$12.34'));
        System.assert(html.contains('2.5'));
        System.assert(html.contains('$30.85'));
        System.assert(html.contains('&lt;script&gt;'));
        System.assert(!html.contains('<script>'));
    }
    @IsTest static void rejectsWrongCodeAndLocksAfterFiveAttempts() {
        List<Invoice_Line_Item__c> lines = new List<Invoice_Line_Item__c>{ item() };
        String token = InvoiceSubmissionController.requestOtp('Test', 'test@example.com', lines);
        for (Integer attempt = 0; attempt < 5; attempt++) {
            System.assertNotEquals(null, InvoiceSubmissionController.verifyAndSubmit('Test', 'test@example.com', lines, token, '000000').error);
        }
        System.assertEquals(5, [SELECT Attempts__c FROM Invoice_Verification__c WHERE Token__c = :token WITH SYSTEM_MODE].Attempts__c);
        System.assertNotEquals(null, InvoiceSubmissionController.verifyAndSubmit(
            'Test', 'test@example.com', lines, token, InvoiceSubmissionController.lastCode).error);
        System.assertEquals(0, [SELECT COUNT() FROM Invoice__c]);
    }
    @IsTest static void rejectsExpiredAndChangedInvoiceAndThrottlesResends() {
        List<Invoice_Line_Item__c> lines = new List<Invoice_Line_Item__c>{ item() };
        String token = InvoiceSubmissionController.requestOtp('Test', 'test@example.com', lines);
        System.assertNotEquals(null, InvoiceSubmissionController.verifyAndSubmit(
            'Changed', 'test@example.com', lines, token, InvoiceSubmissionController.lastCode).error);
        System.assertNotEquals(null, InvoiceSubmissionController.verifyAndSubmit(
            'Test', 'changed@example.com', lines, token, InvoiceSubmissionController.lastCode).error);
        Invoice_Verification__c challenge = [SELECT Expires__c FROM Invoice_Verification__c WHERE Token__c = :token WITH SYSTEM_MODE];
        challenge.Expires__c = System.now().addSeconds(-1);
        update as system challenge;
        System.assertNotEquals(null, InvoiceSubmissionController.verifyAndSubmit(
            'Test', 'test@example.com', lines, token, InvoiceSubmissionController.lastCode).error);
        Boolean throttled = false;
        try { InvoiceSubmissionController.requestOtp('Test', 'test@example.com', lines); }
        catch (AuraHandledException e) { throttled = true; }
        System.assert(throttled, 'Immediate resends must be throttled.');
        System.assertEquals(0, [SELECT COUNT() FROM Invoice__c]);
    }
    @IsTest static void savesCalculatedTotals() {
        Test.startTest();
        Id invoiceId = InvoiceSubmissionController.submitInvoice('Test User', 'test@example.com',
            new List<Invoice_Line_Item__c>{ item(), item() });
        Test.stopTest();
        Invoice__c invoice = [SELECT Name__c, Status__c, Invoice_Total__c FROM Invoice__c WHERE Id = :invoiceId];
        System.assertEquals('Test User', invoice.Name__c);
        System.assertEquals('Pending', invoice.Status__c);
        System.assertEquals(61.70, invoice.Invoice_Total__c);
        List<Invoice_Line_Item__c> saved = [SELECT Name, SubTotal__c FROM Invoice_Line_Item__c WHERE Related_Invoice__c = :invoiceId];
        System.assertEquals(2, saved.size());
        System.assertEquals(30.85, saved[0].SubTotal__c);
        System.assert(saved[0].Name.startsWith('LI-'), 'Salesforce must generate the line-item number.');
        System.assertNotEquals(saved[0].Name, saved[1].Name, 'Line-item numbers must be distinct.');
    }
    @IsTest static void rejectsInvalidInput() {
        Invoice_Line_Item__c invalid = item();
        invalid.Unit9s__c = '-1';
        assertRejected('Test', 'test@example.com', new List<Invoice_Line_Item__c>{ invalid });
        invalid.Unit9s__c = 'oops';
        assertRejected('Test', 'test@example.com', new List<Invoice_Line_Item__c>{ invalid });
        assertRejected('', 'bad', new List<Invoice_Line_Item__c>{ item() });
        assertRejected('Test', 'test@example.com', new List<Invoice_Line_Item__c>());
        invalid = item();
        invalid.Payment_Terms__c = 'Invalid';
        assertRejected('Test', 'test@example.com', new List<Invoice_Line_Item__c>{ invalid });
        System.assertEquals(0, [SELECT COUNT() FROM Invoice__c]);
    }
    @IsTest static void rejectsUserWithoutCreateAccess() {
        // A minimal-access user must not be able to bypass object permissions.
        Profile minimal = [SELECT Id FROM Profile WHERE Name = 'Read Only' LIMIT 1];
        User restricted = new User(Alias = 'invtest', Email = 'invoice@example.com',
            EmailEncodingKey = 'UTF-8', LastName = 'Invoice Test', LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US', ProfileId = minimal.Id, TimeZoneSidKey = 'America/New_York',
            Username = 'invoice.' + UserInfo.getOrganizationId() + '.' + DateTime.now().getTime() + '@example.com');
        insert restricted;
        System.runAs(restricted) {
            assertRejected('Test', 'test@example.com', new List<Invoice_Line_Item__c>{ item() });
        }
        System.assertEquals(0, [SELECT COUNT() FROM Invoice__c]);
    }
    private static void assertRejected(String name, String email, List<Invoice_Line_Item__c> lines) {
        Boolean rejected = false;
        try { InvoiceSubmissionController.submitInvoice(name, email, lines); }
        catch (AuraHandledException e) { rejected = true; }
        System.assert(rejected, 'Invalid or unauthorized submissions must fail.');
    }
}
