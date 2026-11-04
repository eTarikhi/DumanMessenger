/** Optimistic lossless, zero-latency, UNLIMITED-hop temporal contact closure.
 * This is an upper bound, NEVER the five-hop score. Carries persist across partitions.
 */
export function expandContacts(carriers:boolean[], components:number[]):boolean[] {
  const reached=new Set<number>();
  for(let i=0;i<carriers.length;i++)if(carriers[i])reached.add(components[i]);
  return components.map((c,i)=>carriers[i]||reached.has(c));
}
