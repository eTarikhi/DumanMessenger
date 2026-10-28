import { expect,it } from "vitest";
import { expandContacts } from "../../tool/routing/contact_bound";
it("optimistic reachability carries across splits and never loses reached carriers",()=>{
  let state=expandContacts([true,false,false,false],[0,0,2,2]);
  expect(state).toEqual([true,true,false,false]);
  state=expandContacts(state,[0,1,1,3]);
  expect(state).toEqual([true,true,true,false]);
  state=expandContacts(state,[0,1,2,2]);
  expect(state).toEqual([true,true,true,true]);
});
it("does not count unreachable components as contacts or mutate inputs",()=>{
  const source=[true,false,false];expect(expandContacts(source,[0,1,1])).toEqual(source);
  expect(source).toEqual([true,false,false]);
});
