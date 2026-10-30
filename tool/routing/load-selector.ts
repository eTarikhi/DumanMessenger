/** Desktop packaging boundary. Mobile host must verify SHA-256 with a vetted platform API. */
import { createHash } from "node:crypto";
import { openSync, readSync, closeSync } from "node:fs";
import { validateModel } from "../../src/routing-selector";
export function loadSelector(path:string, expectedSHA256:string) {
  try {
    const fd=openSync(path,"r"),buffer=Buffer.alloc(4097);
    let count:number;
    try { count=readSync(fd,buffer,0,buffer.length,0); } finally { closeSync(fd); }
    const raw=buffer.subarray(0,count);
    if(raw.length>4096||!/^[a-f0-9]{64}$/.test(expectedSHA256)||
       createHash("sha256").update(raw).digest("hex")!==expectedSHA256) return null;
    return validateModel(JSON.parse(raw.toString("utf8")));
  } catch {return null;}
}
