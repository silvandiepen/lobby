// SPDX-License-Identifier: MPL-2.0
import { runWork, type WorkRequest } from "./work.ts";

/**
 * The process the background job starts for one piece of work (`work.ts`): the request as JSON on
 * stdin, the answer as JSON on stdout, a failure as a message on stderr and exit code 1.
 */
async function main(): Promise<void> {
  const chunks: Buffer[] = [];
  for await (const chunk of process.stdin) chunks.push(chunk as Buffer);
  const request = JSON.parse(Buffer.concat(chunks).toString("utf8")) as WorkRequest;
  const answer = await runWork(request);
  process.stdout.write(JSON.stringify(answer));
}

main().catch((error: unknown) => {
  process.stderr.write(error instanceof Error ? error.message : String(error));
  process.exitCode = 1;
});
