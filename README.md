 Salesforce Invoice App

A Salesforce Experience Cloud application for submitting invoices with multiple line items, email OTP verification, and automated confirmation emails.

Built with Lightning Web Components (LWC), Apex, and Salesforce custom objects.

## Live Demo

**Visit:** https://ashish-9134-dev-ed.my.site.com/submit

Invoice submission requires an authorized, signed-in Salesforce site account. Email OTP verification confirms access to the entered email address; it does not replace site authentication.

Use sample invoice details and an email address you control when testing.

## What Does It Do?

Users can:

- Enter their name and email address.
- Add or remove invoice line items.
- Enter the description of work, payment terms, units, and contracted rate.
- View calculated line subtotals and the invoice total.
- Verify their email using a six-digit OTP displayed in a pop-up.
- Submit the invoice after successful verification.
- Receive a confirmation email containing the invoice number, submitted name, total, and a table of line items.

New invoices are submitted with **Pending** status. The active invoice statuses are **Pending**, **Approved**, and **Rejected**.

## Submission Flow

1. Enter your name and a valid email address.
2. Add one or more line items.
3. Click **Submit Invoice**.
4. Enter the OTP sent to your email.
5. Click **Verify & Submit Invoice**.
6. View the confirmation and Salesforce-generated invoice number.

The submitted form is cleared after success. The confirmation remains visible for the browser tab’s session.

## Verification and Submission Controls

- OTP codes expire after 10 minutes.
- Each code allows up to five verification attempts.
- Resending a code requires a 60-second interval.
- Changes to invoice details require a new verification code.
- A code cannot be reused after successful submission.
- A maximum of six invoices is permitted per rolling hour, enforced separately by user and email address.
- The invoice trigger also enforces submission limits for direct API and bulk inserts.
- External invoice sharing is Private; line items inherit invoice access.
- Guest submissions are rejected.

These controls reduce abuse but do not replace proper Salesforce permissions, monitoring, or a full security review.

## Main Components

| Component | Purpose |
|-----------|---------|
| `invoiceSubmission` | Invoice form, line-item editor, OTP pop-up, and confirmation |
| `siteHeaderFooter` | Responsive branding using the `HeaderFooter` static resource |
| `InvoiceSubmissionController` | Verification, invoice creation, email delivery, and rate-limit checks |
| `InvoiceSubmissionLimits` | Enforces quotas when invoices are inserted |
| `Invoice__c` | Stores invoice details and status |
| `Invoice_Line_Item__c` | Stores individual invoice lines |
| `Invoice_Verification__c` | Stores OTP hashes, expiry, attempts, and locking state |

## Email Notifications

OTP and invoice confirmation emails use a verified Salesforce
Organization-Wide Email Address with the display name **Invoice Admin**.

For another Salesforce org, configure and verify the sender address and update the controller configuration as needed.

## Development Requirements

- Salesforce org with Experience Cloud enabled
- Salesforce CLI
- VS Code with Salesforce extensions
- Node.js and npm for LWC tests
- Appropriate object, field, and Apex-class permissions
- Configured Salesforce email deliverability
- `HeaderFooter` static resource

The source uses Salesforce API version **68.0**.
