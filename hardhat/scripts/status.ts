/**
 * Print live status for every market.
 *
 *   PREDICT_ADDRESS=0x... npx hardhat run scripts/status.ts
 */
import { formatEther } from "viem";
import { RITUAL, connectRitual, ritual } from "./ritual.ts";

const SCHEDULER_CALL_STATE = ["SCHEDULED", "EXECUTING", "COMPLETED", "CANCELLED", "EXPIRED"] as const;

const SCHEDULER_ABI = [
  {
    type: "function",
    name: "getCallState",
    stateMutability: "view",
    inputs: [{ name: "callId", type: "uint256" }],
    outputs: [{ name: "state", type: "uint8" }],
  },
] as const;

const MARKET_STATUS = ["OPEN", "RESOLVING", "SETTLED", "REFUNDED", "CANCELLED"];
const OUTCOME = ["NONE", "YES", "NO"];

const address = process.env.PREDICT_ADDRESS;
if (!address) throw new Error("Set PREDICT_ADDRESS to the deployed PredictMarket address.");

const { connection, publicClient, viem } = await connectRitual();
const predict = await viem.getContractAt("PredictMarket", address as `0x${string}`);

const [currentBlock, blockTimeMs, executionBalance, count, maxAttempts] = await Promise.all([
  publicClient.getBlockNumber(),
  predict.read.blockTimeMs(),
  predict.read.executionBalance(),
  predict.read.marketCount(),
  predict.read.MAX_ATTEMPTS(),
]);

console.log(`Contract:          ${address}`);
console.log(`Current block:     ${currentBlock}`);
console.log(`Execution balance: ${ritual(executionBalance)}`);
console.log(`Markets:           ${count}`);

const secondsUntil = (target: bigint) =>
  target <= currentBlock ? "now" : `${(Number(target - currentBlock) * Number(blockTimeMs)) / 1000}s`;

for (const market of await predict.read.getMarkets([0n, count])) {
  const pool = market.totalYes + market.totalNo;
  const yesPct = pool === 0n ? 0 : Number((market.totalYes * 10000n) / pool) / 100;

  console.log("");
  console.log(`#${market.id} ${market.question}`);
  console.log(`  state        ${MARKET_STATUS[market.status]}   outcome ${OUTCOME[market.outcome]}`);
  console.log(`  rule         observed ${["?", "?", "?", "?"][market.op]} ${market.target}`);
  console.log(`  oracle       ${market.oracleUrl}  (jq ${market.jsonPath})`);
  console.log(
    `  pool         ${formatEther(pool)} RITUAL ? YES ${yesPct.toFixed(1)}% / NO ${(100 - yesPct).toFixed(1)}%`,
  );
  console.log(`  closes       block ${market.closeBlock} (${secondsUntil(market.closeBlock)})`);
  console.log(`  resolves     block ${market.resolveBlock} (${secondsUntil(market.resolveBlock)})`);
  console.log(`  attempts     ${market.attempts}/${maxAttempts}`);

  if (market.observedValue !== 0n) console.log(`  observed     ${market.observedValue}`);
  if (market.lastError !== "") console.log(`  last error   ${market.lastError}`);

  if (market.scheduleId !== 0n) {
    const state = await publicClient.readContract({
      address: RITUAL.scheduler,
      abi: SCHEDULER_ABI,
      functionName: "getCallState",
      args: [market.scheduleId],
    });
    console.log(`  schedule     id ${market.scheduleId} ? ${SCHEDULER_CALL_STATE[state] ?? state}`);
  }
}

await connection.close();
