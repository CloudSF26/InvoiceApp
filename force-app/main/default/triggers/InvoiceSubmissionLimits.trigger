trigger InvoiceSubmissionLimits on Invoice__c (before insert) {
    InvoiceSubmissionController.enforceSubmissionLimits(Trigger.new);
}
