import { createElement } from 'lwc';
import InvoiceSubmission from 'c/invoiceSubmission';
import { getPicklistValues } from 'lightning/uiObjectInfoApi';
import requestOtp from '@salesforce/apex/InvoiceSubmissionController.requestOtp';
import verifyAndSubmit from '@salesforce/apex/InvoiceSubmissionController.verifyAndSubmit';

jest.mock('@salesforce/apex/InvoiceSubmissionController.requestOtp', () => ({ default: jest.fn() }), { virtual: true });
jest.mock('@salesforce/apex/InvoiceSubmissionController.verifyAndSubmit', () => ({ default: jest.fn() }), { virtual: true });
const flush = async () => { await Promise.resolve(); await Promise.resolve(); };
describe('invoice submission', () => {
    beforeEach(() => {
        sessionStorage.clear();
        HTMLDialogElement.prototype.showModal = jest.fn(function () { this.open = true; });
    });
    afterEach(() => { document.body.innerHTML = ''; jest.clearAllMocks(); });
    async function mount() {
        const element = createElement('c-invoice-submission', { is: InvoiceSubmission });
        document.body.appendChild(element);
        getPicklistValues.emit({ values: [{ label: 'Pay per Hour', value: 'Pay per Hour' }] });
        await flush();
        return element;
    }
    function button(element, label) {
        return [...element.shadowRoot.querySelectorAll('lightning-button')].find(node => node.label === label);
    }
    it('adds and removes line items', async () => {
        const element = await mount();
        button(element, 'Add Line Item').click();
        await flush();
        expect(element.shadowRoot.querySelectorAll('fieldset')).toHaveLength(2);
        button(element, '- Remove Item').click();
        await flush();
        expect(element.shadowRoot.querySelectorAll('fieldset')).toHaveLength(1);
    });
    it('requires email verification before saving and displays confirmation', async () => {
        requestOtp.mockResolvedValue('test-token');
        verifyAndSubmit.mockResolvedValue({ invoiceId: 'a01000000000001AAA', invoiceNumber: 'INV-0042' });
        const element = await mount();
        element.shadowRoot.querySelectorAll('lightning-input, lightning-textarea, lightning-combobox').forEach(input => {
            input.reportValidity = jest.fn(() => true);
            input.setCustomValidity = jest.fn();
            const values = { submitterName: 'Test', email: 'test@example.com', description: 'Work', units: '2', rate: '10', terms: 'Pay per Hour' };
            input.value = values[input.name || input.dataset.field];
            input.dispatchEvent(new CustomEvent('change', { detail: { value: input.value } }));
        });
        await flush();
        button(element, 'Submit Invoice').click();
        await flush();
        expect(requestOtp).toHaveBeenCalledWith(expect.objectContaining({ submitterName: 'Test', lineItems: [expect.objectContaining({ Unit9s__c: '2', Contracted_Rate__c: 10 })] }));
        expect(verifyAndSubmit).not.toHaveBeenCalled();
        expect(element.shadowRoot.querySelector('dialog').open).toBe(true);
        const otp = element.shadowRoot.querySelector('[data-otp]');
        otp.reportValidity = jest.fn(() => true);
        otp.value = '123456';
        otp.dispatchEvent(new CustomEvent('change'));
        button(element, 'Verify & Submit Invoice').click();
        await flush();
        expect(verifyAndSubmit).toHaveBeenCalledWith(expect.objectContaining({ token: 'test-token', code: '123456' }));
        expect(element.shadowRoot.querySelector('[role="status"]').textContent).toContain('Invoice submitted succesfully.');
        expect(element.shadowRoot.querySelector('[role="status"]').textContent).toContain('Reference: INV-0042');
        expect(element.shadowRoot.querySelector('[role="status"]').textContent).not.toContain('a01000000000001AAA');
        expect(button(element, 'Submit another invoice')).toBeUndefined();
        expect(element.shadowRoot.querySelectorAll('lightning-input')).toHaveLength(0);
        document.body.removeChild(element);
        const restored = await mount();
        expect(restored.shadowRoot.querySelector('[role="status"]').textContent).toContain('Reference: INV-0042');
        expect(button(restored, 'Submit Invoice')).toBeUndefined();
        expect(restored.shadowRoot.querySelectorAll('fieldset')).toHaveLength(0);
    });
    it('does not submit invalid input', async () => {
        const element = await mount();
        element.shadowRoot.querySelectorAll('lightning-input, lightning-textarea, lightning-combobox').forEach(input => {
            input.reportValidity = jest.fn(() => false);
            input.setCustomValidity = jest.fn();
        });
        button(element, 'Submit Invoice').click();
        await flush();
        expect(requestOtp).not.toHaveBeenCalled();
        expect(verifyAndSubmit).not.toHaveBeenCalled();
    });
    it('shows an inline error for an incomplete email and does not send a code', async () => {
        const element = await mount();
        element.shadowRoot.querySelectorAll('lightning-input, lightning-textarea, lightning-combobox').forEach(input => {
            input.reportValidity = jest.fn(() => true);
            input.setCustomValidity = jest.fn();
        });
        const email = element.shadowRoot.querySelector('[data-email]');
        email.value = 'name@example';
        email.dispatchEvent(new CustomEvent('change'));
        button(element, 'Submit Invoice').click();
        await flush();
        expect(email.setCustomValidity).toHaveBeenCalledWith(expect.stringContaining('complete email'));
        expect(requestOtp).not.toHaveBeenCalled();
    });
    it('opens the OTP popup when email name is not reflected as an HTML attribute', async () => {
        requestOtp.mockResolvedValue('test-token');
        const element = await mount();
        element.shadowRoot.querySelectorAll('lightning-input, lightning-textarea, lightning-combobox').forEach(input => {
            input.reportValidity = jest.fn(() => true);
            input.setCustomValidity = jest.fn();
        });
        const email = element.shadowRoot.querySelector('[data-email]');
        email.value = 'test@example.com';
        email.dispatchEvent(new CustomEvent('change'));
        email.removeAttribute('name');
        button(element, 'Submit Invoice').click();
        await flush();
        expect(requestOtp).toHaveBeenCalledTimes(1);
        expect(element.shadowRoot.querySelector('dialog').open).toBe(true);
    });
    it('reports a missing email input without requesting an OTP or throwing', async () => {
        const element = await mount();
        element.shadowRoot.querySelectorAll('lightning-input, lightning-textarea, lightning-combobox').forEach(input => {
            input.reportValidity = jest.fn(() => true);
        });
        element.shadowRoot.querySelector('[data-email]').removeAttribute('data-email');
        button(element, 'Submit Invoice').click();
        await flush();
        expect(requestOtp).not.toHaveBeenCalled();
        expect(element.shadowRoot.querySelector('[role="alert"]').textContent).toContain('Unable to locate the email field');
    });
    it('Cancel resets the header and line items', async () => {
        const element = await mount();
        const name = element.shadowRoot.querySelector('[name="submitterName"]');
        name.value = 'Test';
        name.dispatchEvent(new CustomEvent('change'));
        element.shadowRoot.querySelector('[data-email]').setCustomValidity = jest.fn();
        button(element, 'Add Line Item').click();
        await flush();
        button(element, 'Cancel').click();
        await flush();
        expect(element.shadowRoot.querySelector('[name="submitterName"]').value).toBe('');
        expect(element.shadowRoot.querySelector('[data-email]').value).toBe('');
        expect(element.shadowRoot.querySelectorAll('fieldset')).toHaveLength(1);
        expect(requestOtp).not.toHaveBeenCalled();
    });
});
