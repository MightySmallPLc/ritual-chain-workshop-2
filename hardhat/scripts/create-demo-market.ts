/**
 * Create the preset workshop market.
 *
 *   PREDICT_ADDRESS=0x... ORACLE_URL=https://<tunnel>/api/oracle/eth \
 *     npx hardhat run scripts/create-demo-market.ts
 */
import { COMPARATOR, DEMO_MARKET } from "./market-presets.ts";
import { connectRitual, explorerTx } from "./ritual.ts";

const address = process.env.PREDICT_ADDRESS;
if (!address) throw new Error("Set PREDICT_ADDRESS to the deployed PredictMarket address.");

const oracleUrl = process.env.ORACLE_URL ?? DEMO_MARKET.oracleUrl;
if (oracleUrl.includes("localhost") || oracleUrl.includes("127.0.0.1")) {
  throw new Error(
    "The oracle URL is fetched by a TEE executor in the cloud, so localhost will never resolve."
  );
}

const comparatorKey = (process.env.COMPARATOR ?? DEMO_MARKET.comparator) as keyof typeof COMPARATOR;
const comparator = COMPARATOR[comparatorKey];
if (comparator === undefined) {
  throw new Error(`COMPARATOR must be one of: ${Object.keys(COMPARATOR).join(", ")}`);
}

const params = {
  question: process.env.QUESTION ?? DEMO_MARKET.question,
  oracleUrl,
  jsonPath: process.env.JSON_PATH ?? DEMO_MARKET.jsonPath,
  target: BigInt(process.env.TARGET ?? DEMO_MARKET.target),
  comparator,
  bettingSeconds: BigInt(process.env.BETTING_SECONDS ?? DEMO_MARKET.bettingSeconds),
  resolveDelaySeconds: BigInt(process.env.RESOLVE_DELAY_SECONDS ?? DEMO_MARKET.resolveDelaySeconds),
} as const;

const { connection, publicClient, viem } = await connectRitual();
const predict = await viem.getContractAt("PredictMarket", address as `0x${string}`);

const executionBalance = await predict.read.executionBalance();
if (executionBalance === 0n) {
  console.warn("! Execution balance is 0 ? the scheduled resolution will be skipped.");
}

console.log(`Question:   ${params.question}`);
console.log(`Rule:       observed ${comparatorKey.toUpperCase()} ${params.target}`);
console.log(`Oracle:     ${params.oracleUrl}  (jq: ${params.jsonPath})`);
console.log(`Betting:    ${params.bettingSeconds}s, then resolve after ${params.resolveDelaySeconds}s`);
console.log("");

const spec = {
  question: params.question,
  oracleUrl: params.oracleUrl,
  jsonPath: params.jsonPath,
  target: params.target,
  op: params.comparator,
  bettingSeconds: params.bettingSeconds,
  resolveDelaySeconds: params.resolveDelaySeconds,
};

const hash = await predict.write.createMarket([spec]);
const receipt = await publicClient.waitForTransactionReceipt({ hash });

const marketId = await predict.read.marketCount();
const market = await predict.read.getMarket([marketId]);

console.log(`Created market #${marketId} in block ${receipt.blockNumber}`);
console.log(`Betting closes at block ${market.closeBlock}`);
console.log(`Scheduler fires at block ${market.resolveBlock} (schedule id ${market.scheduleId})`);
console.log(`${explorerTx(hash)}`);

await connection.close();
