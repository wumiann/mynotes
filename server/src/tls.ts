import fs from 'node:fs';
import path from 'node:path';
import forge from 'node-forge';
import { config } from './config.js';

export interface CertPaths {
  key: string;
  cert: string;
}

// 局域网 HTTPS 用：首次启动自动生成自签名证书（有效期 10 年），存放在 data/certs/
export function ensureSelfSignedCert(): CertPaths {
  const dir = path.join(config.dataDir, 'certs');
  fs.mkdirSync(dir, { recursive: true });
  const keyPath = path.join(dir, 'selfsigned-key.pem');
  const certPath = path.join(dir, 'selfsigned-cert.pem');
  if (fs.existsSync(keyPath) && fs.existsSync(certPath)) {
    return { key: keyPath, cert: certPath };
  }
  const keys = forge.pki.rsa.generateKeyPair(2048);
  const cert = forge.pki.createCertificate();
  cert.publicKey = keys.publicKey;
  cert.serialNumber = String(Date.now());
  cert.validity.notBefore = new Date();
  cert.validity.notAfter = new Date(Date.now() + 10 * 365 * 24 * 3600 * 1000);
  const attrs = [{ name: 'commonName', value: 'mynotes-lan' }];
  cert.setSubject(attrs);
  cert.setIssuer(attrs);
  cert.sign(keys.privateKey, forge.md.sha256.create());
  fs.writeFileSync(keyPath, forge.pki.privateKeyToPem(keys.privateKey));
  fs.writeFileSync(certPath, forge.pki.certificateToPem(cert));
  return { key: keyPath, cert: certPath };
}
