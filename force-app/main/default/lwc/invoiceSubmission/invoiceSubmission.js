import { LightningElement, wire } from 'lwc';
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import LINE_ITEM from '@salesforce/schema/Invoice_Line_Item__c';
import PAYMENT_TERMS from '@salesforce/schema/Invoice_Line_Item__c.Payment_Terms__c';
import requestOtp from '@salesforce/apex/InvoiceSubmissionController.requestOtp';
import verifyAndSubmit from '@salesforce/apex/InvoiceSubmissionController.verifyAndSubmit';
import userId from '@salesforce/user/Id';

const CONFIRMATION_KEY = `invoiceSubmission:confirmation:${userId}`;

export default class InvoiceSubmission extends LightningElement {
    submitterName = '';
    email = '';
    rows = [];
    nextKey = 0;
    saving = false;
    error = '';
    invoiceId;
    invoiceNumber;
    paymentOptions = [];
    otpToken;
    otpCode = '';

    get formError() { return !this.otpToken && this.error; }
    renderedCallback() {
        const dialog = this.template.querySelector('dialog');
        if (dialog && !dialog.open) {
            dialog.showModal();
            this.template.querySelector('[data-otp]')?.focus();
        }
        if (this.restoreSubmitFocus && !dialog) {
            this.restoreSubmitFocus = false;
            this.template.querySelector('[data-submit]')?.focus();
        }
    }
    closeOtp() {
        if (this.saving) return;
        this.restoreSubmitFocus = true;
        this.clearOtp();
        this.error = '';
    }
    handleModalCancel(event) {
        event.preventDefault();
        this.closeOtp();
    }
    cancelInvoice() {
        if (this.saving) return;
        this.submitterName = '';
        this.email = '';
        this.template.querySelector('[data-email]')?.setCustomValidity('');
        this.startAgain();
    }
    validateEmail(input) {
        const valid = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(this.email);
        if (!input) {
            this.error = 'Unable to locate the email field. Please refresh the page and try again.';
            return false;
        }
        input.setCustomValidity(valid ? '' : 'Enter a complete email address, such as name@example.com.');
        return input.reportValidity() && valid;
    }
    clearOtp() { this.otpToken = undefined; this.otpCode = ''; }
    handleOtp(event) { this.otpCode = event.target.value; }
    get invoicePayload() {
        return { submitterName: this.submitterName, email: this.email,
            lineItems: this.rows.map(row => ({
                sobjectType: 'Invoice_Line_Item__c', Description_of_Work__c: row.description,
                Payment_Terms__c: row.terms, Unit9s__c: row.units, Contracted_Rate__c: Number(row.rate)
            })) };
    }

    @wire(getObjectInfo, { objectApiName: LINE_ITEM }) objectInfo;
    @wire(getPicklistValues, {
        recordTypeId: '$objectInfo.data.defaultRecordTypeId', fieldApiName: PAYMENT_TERMS
    }) wiredTerms({ data, error }) {
        if (data) this.paymentOptions = data.values;
        if (error) this.error = 'Unable to load payment terms. Contact your site administrator.';
    }

    connectedCallback() {
        try {
            const receipt = JSON.parse(sessionStorage.getItem(CONFIRMATION_KEY));
            if (receipt && typeof receipt.invoiceId === 'string' && typeof receipt.invoiceNumber === 'string') {
                this.invoiceId = receipt.invoiceId;
                this.invoiceNumber = receipt.invoiceNumber;
                return;
            }
        } catch {
            // Storage may be unavailable; retain normal in-memory behavior.
        }
        this.addLine();
    }
    get disableAdd() { return this.saving || !!this.invoiceId || this.rows.length >= 100; }
    get disableSubmit() { return this.saving || !!this.invoiceId || !this.paymentOptions.length; }
    get total() { return this.rows.reduce((sum, row) => sum + row.subtotal, 0); }

    addLine() {
        if (this.disableAdd) return;
        this.clearOtp();
        this.rows = [...this.rows, { key: String(++this.nextKey), description: '', terms: '', units: '1', rate: '', subtotal: 0 }];
        this.numberRows();
    }
    removeLine(event) {
        if (this.saving || this.rows.length === 1) return;
        this.clearOtp();
        this.rows = this.rows.filter(row => row.key !== event.target.dataset.key);
        this.numberRows();
    }
    numberRows() {
        this.rows = this.rows.map((row, index) => ({ ...row, label: `Line item ${index + 1}`, disableRemove: this.saving || this.rows.length === 1 }));
    }
    handleHeader(event) {
        this.clearOtp();
        this[event.target.name] = event.target.value;
        if (event.target.name === 'email') this.validateEmail(event.target);
    }
    handleLine(event) {
        this.clearOtp();
        const { key, field } = event.target.dataset;
        const value = event.detail.value;
        if (field === 'units') {
            event.target.setCustomValidity(String(value).length > 4 ? 'Units must fit within four characters, including the decimal point.' : '');
            event.target.reportValidity();
        }
        this.rows = this.rows.map(row => {
            if (row.key !== key) return row;
            const updated = { ...row, [field]: value };
            updated.subtotal = Math.round((Number(updated.units) * Number(updated.rate) || 0) * 100) / 100;
            return updated;
        });
    }
    async handleSubmit() {
        if (this.disableSubmit) return;
        const emailValid = this.validateEmail(this.template.querySelector('[data-email]'));
        const valid = [...this.template.querySelectorAll('lightning-input:not([data-otp]), lightning-textarea, lightning-combobox')]
            .reduce((result, input) => input.reportValidity() && result, true);
        if (!valid || !emailValid) return;
        this.saving = true;
        this.numberRows();
        this.error = '';
        try {
            this.otpToken = await requestOtp(this.invoicePayload);
            this.otpCode = '';
        } catch (error) {
            this.error = error.body?.message || 'Unable to submit your invoice. Please try again.';
        } finally {
            this.saving = false;
            this.numberRows();
        }
    }
    async verifyOtp() {
        if (this.saving || !this.otpToken) return;
        const input = this.template.querySelector('[data-otp]');
        if (!input.reportValidity()) return;
        this.saving = true;
        this.error = '';
        this.numberRows();
        try {
            const result = await verifyAndSubmit({ ...this.invoicePayload, token: this.otpToken, code: this.otpCode });
            if (result.invoiceId) {
                this.invoiceId = result.invoiceId;
                this.invoiceNumber = result.invoiceNumber;
                this.clearOtp();
                this.submitterName = '';
                this.email = '';
                this.rows = [];
                try {
                    sessionStorage.setItem(CONFIRMATION_KEY, JSON.stringify({
                        invoiceId: this.invoiceId, invoiceNumber: this.invoiceNumber
                    }));
                } catch {
                    // A storage restriction must not turn a saved invoice into an error.
                }
            } else {
                this.error = result.error;
            }
        } catch (error) {
            this.error = error.body?.message || 'Unable to verify your code. Please try again.';
        } finally {
            this.saving = false;
            this.numberRows();
        }
    }
    resendOtp() {
        return this.handleSubmit();
    }
    startAgain() {
        this.clearOtp();
        this.invoiceId = undefined;
        this.invoiceNumber = undefined;
        this.rows = [];
        this.error = '';
        this.addLine();
    }
}
