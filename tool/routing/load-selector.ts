/** Desktop packaging boundary. Mobile host must verify SHA-256 with a vetted platform API. */
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { validateModel } from "../../src/routing-selector";
export function loadSelector(path:string, expectedSHA256:string) {
  try {
    const raw=readFileSync(path);
    if(raw.length>4096||!/^[a-f0-9]{64}$/.test(expectedSHA256)||
       createHash("sha256").update(raw).digest("hex")!==expectedSHA256) return null;
    return validateModel(JSON.parse(raw.toString("utf8")));
  } catch {return null;}
}
