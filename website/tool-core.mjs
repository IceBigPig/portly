// The website's byte tools run locally and do not access devices or a server.
export function parseHex(input) {
  const compact = input.replace(/\s/g, "");
  if (!compact) return [];
  if (!/^[0-9a-f]+$/i.test(compact) || compact.length % 2)
    throw new Error("hex");
  if (compact.length > 8192) throw new Error("length");
  return compact.match(/../g).map((byte) => parseInt(byte, 16));
}
export function hex(bytes) {
  return Array.from(bytes, (byte) =>
    byte.toString(16).padStart(2, "0").toUpperCase(),
  ).join(" ");
}
export function crc16(bytes) {
  let crc = 0xffff;
  for (const byte of bytes) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++)
      crc = crc & 1 ? (crc >>> 1) ^ 0xa001 : crc >>> 1;
  }
  return crc;
}
export function modbusCommand(unit, start, quantity) {
  if (
    !Number.isInteger(unit) ||
    unit < 1 ||
    unit > 247 ||
    !/^[0-9a-f]{1,4}$/i.test(start) ||
    !/^[0-9a-f]{1,4}$/i.test(quantity)
  )
    throw new Error("parameters");
  const address = parseInt(start, 16),
    count = parseInt(quantity, 16);
  if (count < 1 || count > 125 || address + count > 65536)
    throw new Error("parameters");
  const body = [unit, 3, address >> 8, address & 255, count >> 8, count & 255];
  const crc = crc16(body);
  return hex([...body, crc & 255, crc >> 8]);
}
export function convertBase(input) {
  const value = input.trim();
  if (!/^(?:0[xX][\da-fA-F]+|0[bB][01]+|\d+)$/.test(value) || value.length > 66)
    throw new Error("number");
  const integer = BigInt(value);
  if (integer > 0xffffffffffffffffn) throw new Error("number");
  return {
    hex: "0x" + integer.toString(16).toUpperCase(),
    decimal: integer.toString(),
    binary: "0b" + integer.toString(2),
  };
}
export function reverseBytes(input) {
  const bytes = parseHex(input);
  if (![2, 4, 8].includes(bytes.length)) throw new Error("endian");
  return {
    reversed: hex([...bytes].reverse()),
    unsigned: BigInt("0x" + hex(bytes).replaceAll(" ", "")).toString(),
  };
}
export function nmeaChecksum(input) {
  const body = input.trim().replace(/^\$/, "").split("*")[0];
  if (!body || body.length > 1024 || /[^\x20-\x7e]/.test(body))
    throw new Error("nmea");
  let sum = 0;
  for (const char of body) sum ^= char.charCodeAt(0);
  const checksum = sum.toString(16).padStart(2, "0").toUpperCase();
  return { checksum, sentence: "$" + body + "*" + checksum };
}
