import { LightningElement, api } from 'lwc';
import headerFooterResource from '@salesforce/resourceUrl/HeaderFooter';

export default class SiteHeaderFooter extends LightningElement {
    @api alternativeText = 'Site branding';
    @api imagePath = '';

    get imageUrl() {
        const path = (this.imagePath || '').trim().replace(/^\/+/, '');
        return path ? `${headerFooterResource}/${path}` : headerFooterResource;
    }
}
