const BYTE_LIMIT = 256 * 1024;
const IDENTIFIER = /^[A-Za-z0-9_-]+$/;

function doPost(e) {
  const properties = PropertiesService.getScriptProperties();
  const key = properties.getProperty('ACCESS_KEY') || '';
  const folder = properties.getProperty('FOLDER_ID') || '';
  const body = e && e.postData && e.postData.contents;
  if (!body || body.length > 1024 || key.length < 24 || key.length > 128 ||
      !IDENTIFIER.test(key) || !IDENTIFIER.test(folder)) {
    return json({ok: false, error: 'Acesso indisponível'});
  }

  try {
    const request = JSON.parse(body);
    if (!request || !equalKey(request.key, key)) {
      return json({ok: false, error: 'Chave de acesso incorreta'});
    }
    if (request.action === 'photo') return photoInFolder(folder, request.id);
    if (request.action === 'list') return listPhotos(folder, request.revision);
    return json({ok: false, error: 'Atualize a ponte das fotos'});
  } catch (error) {
    return json({ok: false, error: 'Confira a pasta e a autorização do Drive'});
  }
}

function isImage(file) {
  return !file.isTrashed() && file.getMimeType().startsWith('image/');
}

function listPhotos(folder, knownRevision) {
  const files = DriveApp.getFolderById(folder).getFiles();
  const entries = [];
  while (files.hasNext()) {
    const file = files.next();
    if (isImage(file)) entries.push([file.getId(), file.getLastUpdated().getTime()]);
  }
  entries.sort((a, b) => a[0].localeCompare(b[0]));
  const revision = Utilities.base64EncodeWebSafe(
    Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, JSON.stringify(entries))
  );
  return knownRevision === revision ? json({ok: true, unchanged: true}) :
    json({ok: true, revision, ids: entries.map(entry => entry[0])});
}

function photoInFolder(folder, id) {
  if (typeof id !== 'string' || id.length > 128 || !IDENTIFIER.test(id)) {
    return json({ok: false, error: 'Foto indisponível'});
  }
  const file = DriveApp.getFileById(id);
  const parents = file.getParents();
  let belongs = false;
  while (parents.hasNext()) {
    if (parents.next().getId() === folder) {
      belongs = true;
      break;
    }
  }
  if (!belongs || !isImage(file)) return json({ok: false, error: 'Foto indisponível'});

  const original = /^(image\/jpeg|image\/png)$/.test(file.getMimeType()) && file.getSize() <= BYTE_LIMIT;
  const blob = original ? file.getBlob() : file.getThumbnail();
  const bytes = blob && blob.getBytes();
  if (!bytes || !bytes.length || bytes.length > BYTE_LIMIT ||
      !/^(image\/jpeg|image\/png)$/.test(blob.getContentType())) {
    return json({ok: false, error: 'Prévia indisponível'});
  }
  return json({ok: true, image: Utilities.base64Encode(bytes)});
}

function equalKey(input, expected) {
  if (typeof input !== 'string' || input.length !== expected.length) return false;
  let difference = 0;
  for (let i = 0; i < expected.length; i++) {
    difference |= input.charCodeAt(i) ^ expected.charCodeAt(i);
  }
  return difference === 0;
}

function json(value) {
  return ContentService.createTextOutput(JSON.stringify(value))
    .setMimeType(ContentService.MimeType.JSON);
}
