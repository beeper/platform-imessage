import { decodeAttributedString } from './lib/index'
import fs from 'fs/promises';

(async () => {
    const buf = await fs.readFile(process.argv[2]);
    console.log(decodeAttributedString(buf));
})();
