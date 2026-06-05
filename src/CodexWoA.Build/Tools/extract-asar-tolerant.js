const fs = require('node:fs');
const path = require('node:path');

const archivePath = path.resolve(process.argv[1]);
const destination = path.resolve(process.argv[2]);
const unpackedRoot = `${archivePath}.unpacked`;

function readExactly(fd, buffer, position) {
  let read = 0;
  while (read < buffer.length) {
    const count = fs.readSync(fd, buffer, read, buffer.length - read, position + read);
    if (count === 0) {
      throw new Error(`Unexpected end of file while reading ${archivePath}`);
    }

    read += count;
  }
}

function readArchiveHeader() {
  const fd = fs.openSync(archivePath, 'r');
  try {
    const sizePickle = Buffer.alloc(8);
    readExactly(fd, sizePickle, 0);
    const headerSize = sizePickle.readUInt32LE(4);
    if (headerSize < 8) {
      throw new Error(`Invalid ASAR header size: ${headerSize}`);
    }

    const headerPickle = Buffer.alloc(headerSize);
    readExactly(fd, headerPickle, 8);
    const headerStringSize = headerPickle.readInt32LE(4);
    const headerStart = 8;
    const headerEnd = headerStart + headerStringSize;
    if (headerEnd > headerPickle.length) {
      throw new Error(`Invalid ASAR header string size: ${headerStringSize}`);
    }

    return {
      header: JSON.parse(headerPickle.toString('utf8', headerStart, headerEnd)),
      dataStart: 8 + headerSize,
    };
  } finally {
    fs.closeSync(fd);
  }
}

function assertInsideDestination(targetPath, label) {
  const relative = path.relative(destination, targetPath);
  if (relative.startsWith('..') || path.isAbsolute(relative)) {
    throw new Error(`${label} writes outside the extraction directory: ${targetPath}`);
  }
}

const { header, dataStart } = readArchiveHeader();
const fd = fs.openSync(archivePath, 'r');
const missingUnpacked = [];

function extractNode(node, relativePath) {
  const targetPath = path.join(destination, relativePath);
  assertInsideDestination(targetPath, relativePath || '.');

  if (node.files) {
    fs.mkdirSync(targetPath, { recursive: true });
    for (const [name, child] of Object.entries(node.files)) {
      extractNode(child, path.join(relativePath, name));
    }

    return;
  }

  fs.mkdirSync(path.dirname(targetPath), { recursive: true });

  if (node.link) {
    const linkSrcPath = path.dirname(path.join(destination, node.link));
    assertInsideDestination(linkSrcPath, node.link);
    const linkDestPath = path.dirname(targetPath);
    const relativeLink = path.join(path.relative(linkDestPath, linkSrcPath), path.basename(node.link));
    try {
      fs.unlinkSync(targetPath);
    } catch {
    }

    fs.symlinkSync(relativeLink, targetPath);
    return;
  }

  if (node.unpacked) {
    const sourcePath = path.join(unpackedRoot, relativePath);
    if (fs.existsSync(sourcePath)) {
      fs.copyFileSync(sourcePath, targetPath);
      return;
    }

    missingUnpacked.push(relativePath);
    return;
  }

  const size = Number(node.size || 0);
  if (size <= 0) {
    fs.writeFileSync(targetPath, Buffer.alloc(0));
    return;
  }

  const offset = dataStart + Number(node.offset || 0);
  const buffer = Buffer.alloc(size);
  readExactly(fd, buffer, offset);
  fs.writeFileSync(targetPath, buffer);
  if (node.executable && process.platform !== 'win32') {
    fs.chmodSync(targetPath, 0o755);
  }
}

try {
  fs.mkdirSync(destination, { recursive: true });
  extractNode(header, '');
} finally {
  fs.closeSync(fd);
}

for (const relativePath of missingUnpacked) {
  console.warn(`Skipping missing ASAR unpacked file: ${relativePath}`);
}