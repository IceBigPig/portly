import test from "node:test";
import assert from "node:assert/strict";
import {
  parseHex,
  hex,
  crc16,
  modbusCommand,
  convertBase,
  reverseBytes,
  nmeaChecksum,
} from "./tool-core.mjs";
test("Modbus CRC matches the documented request and standard check vector", () => {
  assert.equal(crc16(parseHex("01 03 00 00 00 02")), 0x0bc4);
  assert.equal(crc16(new TextEncoder().encode("123456789")), 0x4b37);
  assert.equal(modbusCommand(1, "0000", "0002"), "01 03 00 00 00 02 C4 0B");
});
test("HEX accepts contiguous bytes and whitespace, rejects ambiguous or oversized input", () => {
  assert.equal(hex(parseHex("aBcd\n00\tFF")), "AB CD 00 FF");
  for (const input of ["123", "0x01", "GG", "01-02", "AA".repeat(4097)])
    assert.throws(() => parseHex(input));
});
test("register commands reject invalid ranges and address overflow", () => {
  for (const args of [
    [0, "0", "1"],
    [248, "0", "1"],
    [1, "ZZ", "2"],
    [1, "0000", "0000"],
    [1, "0", "007E"],
    [1, "FFFF", "2"],
  ])
    assert.throws(() => modbusCommand(...args));
  assert.match(modbusCommand(247, "FFFF", "1"), /^F7 03 FF FF 00 01 /);
});
test("integer conversion preserves all 64 bits and rejects invalid numbers", () => {
  assert.equal(
    convertBase("0xFFFFFFFFFFFFFFFF").decimal,
    "18446744073709551615",
  );
  assert.equal(convertBase("0b1010").hex, "0xA");
  assert.equal(convertBase("3000").hex, "0xBB8");
  for (const input of ["-1", "1.5", "1e3", "0b2", "18446744073709551616"])
    assert.throws(() => convertBase(input));
});
test("byte order reverses complete words without dropping leading zeroes", () => {
  assert.deepEqual(reverseBytes("00 00 12 34"), {
    reversed: "34 12 00 00",
    unsigned: "4660",
  });
  assert.throws(() => reverseBytes("01 02 03"));
});
test("NMEA checksum excludes framing and an existing checksum", () => {
  assert.deepEqual(nmeaChecksum("$GPGLL,4916.45,N,12311.12,W,225444,A*00"), {
    checksum: "31",
    sentence: "$GPGLL,4916.45,N,12311.12,W,225444,A*31",
  });
  assert.throws(() => nmeaChecksum("中文"));
  assert.throws(() => nmeaChecksum(""));
});
