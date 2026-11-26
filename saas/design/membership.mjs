import {tr} from './i18n.mjs';
export const membershipTiers=Object.freeze(["standard","silver","gold","vip","wholesale","member"]);
const labels=Object.freeze({standard:'عادي',silver:'فضي',gold:'ذهبي',vip:'VIP',wholesale:'جملة',member:'عضوية سابقة'});
export const membershipLabel=t=>tr(labels[t]||t);
export const validMembershipTier=t=>membershipTiers.includes(t);
