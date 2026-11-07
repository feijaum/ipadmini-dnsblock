const PHOTO_LIMIT = 20;
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

    const files = DriveApp.getFolderById(folder).getFiles();
    const recent = [];
    while (files.hasNext()) {
      const file = files.next();
      const mime = file.getMimeType();
      if (file.isTrashed() || !mime.startsWith('image/')) continue;
      recent.push({
        file,
        mime,
        id: file.getId(),
        created: file.getDateCreated().getTime(),
        modified: file.getLastUpdated().getTime()
      });
      recent.sort((a, b) => b.created - a.created || a.id.localeCompare(b.id));
      if (recent.length > PHOTO_LIMIT) recent.pop();
    }

    const versions = recent.map(item => item.id + ':' + item.modified).join(',');
    const revision = Utilities.base64EncodeWebSafe(
      Utilities.computeDigest(Utilities.DigestAlgorithm.SHA_256, versions)
    );
    if (request.revision === revision) return json({ok: true, unchanged: true});

    const photos = [];
    let incomplete = false;
    for (const item of recent) {
      try {
        const original = /^(image\/jpeg|image\/png)$/.test(item.mime) &&
          item.file.getSize() <= BYTE_LIMIT;
        const blob = original ? item.file.getBlob() : item.file.getThumbnail();
        const bytes = blob && blob.getBytes();
        if (!bytes || !bytes.length || bytes.length > BYTE_LIMIT ||
            !/^(image\/jpeg|image\/png)$/.test(blob.getContentType())) {
          incomplete = true;
          continue;
        }
        photos.push(Utilities.base64Encode(bytes));
      } catch (error) {
        incomplete = true;
      }
    }
    return json({ok: true, revision: incomplete ? '' : revision, photos, incomplete});
  } catch (error) {
    return json({ok: false, error: 'Confira a pasta e a autorização do Drive'});
  }
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
