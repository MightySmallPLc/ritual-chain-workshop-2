import assert from "node:assert/strict";
import { describe, it } from "node:test";
import { encodeAbiParameters, hexToString, parseAbiParameters, stringToHex } from "viem";
import { network } from "hardhat";

const envelope = parseAbiParameters("bytes simmedInput, bytes actualOutput");
const response = parseAbiParameters("uint16 status, string[] keys, string[] values, bytes body, string errorMessage");

describe("PredictMarket local safety checks", async () => {
  const { viem } = await network.create();
  const market = await viem.deployContract("PredictMarket", [195n]);
  const [creator, trader] = await viem.getWalletClients();

  const spec = {
    question: "Will the signal exceed 100?",
    oracleUrl: "https://oracle.example/signal",
    jsonPath: ".value",
    target: 100n,
    op: 1, // GTE
    bettingSeconds: 60n,
    resolveDelaySeconds: 30n,
  } as const;

  it("decodes a settled HTTP result", async () => {
    const output = encodeAbiParameters(response, [200, [], [], stringToHex('{"price":4200}'), ""]);
    const decoded = await market.read.decodeHttpResponse([encodeAbiParameters(envelope, ["0x", output])]);
    assert.equal(decoded[0], 200);
    assert.equal(hexToString(decoded[1]), '{"price":4200}');
  });

  it("rejects an unfinished async result", async () => {
    await assert.rejects(
      market.read.decodeHttpResponse([encodeAbiParameters(envelope, ["0x", "0x"])]),
      /async output not settled/,
    );
  });

  it("returns empty for getMarkets with out-of-bound page", async () => {
    assert.deepEqual(await market.read.getMarkets([0n, 10n]), []);
  });

  it("opens a market, accepts a stake, and allows the creator to cancel before close", async () => {
    await market.write.createMarket([spec]);
    const id = await market.read.marketCount();
    
    // bet YES
    await market.write.bet([id, true], { account: trader.account, value: 1_000_000_000_000_000n });

    const beforeCancel = await market.read.getMarket([id]);
    assert.equal(beforeCancel.totalYes, 1_000_000_000_000_000n);
    assert.equal(beforeCancel.totalNo, 0n);

    // cancel
    await market.write.cancelMarket([id], { account: creator.account });
    const afterCancel = await market.read.getMarket([id]);
    assert.equal(afterCancel.status, 4); // Cancelled (enum value 4)
    
    assert.equal(await market.read.yesStakes([id, trader.account.address]), 1_000_000_000_000_000n);
  });
});
