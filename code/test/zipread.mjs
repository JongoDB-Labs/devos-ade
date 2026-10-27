// A minimal zip reader for the tests (central directory + zlib): {name -> {data, mode}}, checking every CRC and size.
import zlib from 'node:zlib';

export function readZip(buf) {
  const eocd = buf.length - 22;
  if (eocd < 0 || buf.readUInt32LE(eocd) !== 0x06054b50) throw new Error('no end-of-central-directory record');
  const n = buf.readUInt16LE(eocd + 10), cdSize = buf.readUInt32LE(eocd + 12), cdStart = buf.readUInt32LE(eocd + 16);
  if (cdStart + cdSize !== eocd) throw new Error('central directory is not where the end record says');
  const out = {};
  let p = cdStart;
  for (let i = 0; i < n; i++) {
    if (buf.readUInt32LE(p) !== 0x02014b50) throw new Error('bad central header');
    const method = buf.readUInt16LE(p + 10), crc = buf.readUInt32LE(p + 16), csize = buf.readUInt32LE(p + 20), usize = buf.readUInt32LE(p + 24);
    const nl = buf.readUInt16LE(p + 28), el = buf.readUInt16LE(p + 30), cl = buf.readUInt16LE(p + 32), attr = buf.readUInt32LE(p + 38), lho = buf.readUInt32LE(p + 42);
    const name = buf.subarray(p + 46, p + 46 + nl).toString('utf8');
    if (buf.readUInt32LE(lho) !== 0x04034b50) throw new Error('bad local header');
    const lnl = buf.readUInt16LE(lho + 26), lel = buf.readUInt16LE(lho + 28);
    const raw = buf.subarray(lho + 30 + lnl + lel, lho + 30 + lnl + lel + csize);
    const data = method === 8 ? zlib.inflateRawSync(raw) : raw;
    if (data.length !== usize) throw new Error(`${name}: size`);
    if ((zlib.crc32(data) >>> 0) !== crc) throw new Error(`${name}: crc`);
    // the data descriptor follows the data: it says the same
    const dd = lho + 30 + lnl + lel + csize;
    if (buf.readUInt32LE(dd) !== 0x08074b50 || buf.readUInt32LE(dd + 4) !== crc || buf.readUInt32LE(dd + 8) !== csize || buf.readUInt32LE(dd + 12) !== usize) throw new Error(`${name}: descriptor`);
    out[name] = { data, mode: (attr >>> 16) & 0o777 };
    p += 46 + nl + el + cl;
  }
  return out;
}
