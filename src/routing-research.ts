/** Offline-only finite registry. Not accepted by the live selector artifact API.
 * Dart has no equivalent candidate: no production eligibility is implied.
 */
export type RoutingResearchProfile = 'baseline' | 'ogm-epoch-v1' | 'source-backup-v1';
export function validateResearchProfile(value: unknown): asserts value is RoutingResearchProfile {
  if(value!=='baseline'&&value!=='ogm-epoch-v1'&&value!=='source-backup-v1')throw new Error('Unknown routing research profile');
}
export const OGM_EPOCH_PROFILE = Object.freeze({api:1,id:'ogm-epoch-v1',runtime:'typescript-only',productionEligible:false});
