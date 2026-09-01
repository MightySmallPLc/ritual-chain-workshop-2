/**
 * Top up a deployed PredictMarket's prepaid execution balance.
 *
 *   PREDICT_ADDRESS=0x... AMOUNT=0.5 npx hardhat run scripts/fund.ts
 */
import { parseEther } from "viem";
import { connectRitual, explorerTx, ritual } from "./ritual.ts";

const FUNDING_LOCK_BLOCKS = 500_000n;

const address = process.env.PREDICT_ADDRESS;
if (!address) throw new Error("Set PREDICT_ADDRESS to the deployed PredictMarket address.");

const { connection, publicClient, viem } = await connectRitual();
const predict = await viem.getContractAt("PredictMarket", address as `0x${string}`);

const before = await predict.read.executionBalance();
console.log(`Execution balance before: ${ritual(before)}`);

const amount = parseEther(process.env.AMOUNT ?? "0.5");
const hash = await predict.write.fundExecution([FUNDING_LOCK_BLOCKS], { value: amount });
await publicClient.waitForTransactionReceipt({ hash });

const after = await predict.read.executionBalance();
console.log(`Deposited:                ${ritual(amount)}`);
console.log(`Execution balance after:  ${ritual(after)}`);
console.log(`                          ${explorerTx(hash)}`);

await connection.close();
