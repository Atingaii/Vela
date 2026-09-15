"""Check literal UI translation references against both actual dictionaries.

This complements browser locale checks: equal dictionary sizes alone cannot
detect a key missing from both languages. Dynamic references and unmarked prose
still require real UI inspection; source content is never translated by this test.
"""
import argparse
import json
from pathlib import Path
import re
import subprocess

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--ui-directory', type=Path, default=ROOT/'Sources/VelaApp/Resources/UI')
args = parser.parse_args()
ui = args.ui_directory.resolve(strict=True)
program = """
const fs=require('node:fs'),vm=require('node:vm');
const context={window:{}};vm.createContext(context);
vm.runInContext(fs.readFileSync(process.argv[1],'utf8'),context,{timeout:1000});
const dictionary=context.window.VelaI18n.DICTIONARY;
process.stdout.write(JSON.stringify(Object.fromEntries(Object.entries(dictionary).map(([locale,values])=>[locale,Object.keys(values)]))));
"""
result = subprocess.run(['node','-e',program,str(ui/'i18n.js')],capture_output=True,text=True,check=True,timeout=5)
dictionaries = {locale:set(keys) for locale,keys in json.loads(result.stdout).items()}
assert set(dictionaries)=={'zh-CN','en'}
references = set()
patterns = [r"\bt(?:Html)?\(\s*['\"]([a-zA-Z][\w.-]*\.[\w.-]+)['\"]",
            r"data-i18n(?:-title|-placeholder|-aria-label)?=['\"]([a-zA-Z][\w.-]*\.[\w.-]+)['\"]",
            r"\b(?:key|labelKey|titleKey|descriptionKey):\s*['\"]([a-zA-Z][\w.-]*\.[\w.-]+)['\"]"]
for name in ('app.js','index.html'):
    source = (ui/name).read_text()
    for pattern in patterns:
        references.update(re.findall(pattern,source))
missing = {locale:sorted(references-keys) for locale,keys in dictionaries.items()}
parity = {locale:sorted(set.union(*dictionaries.values())-keys) for locale,keys in dictionaries.items()}
print(json.dumps({'literalReferences':len(references),'dictionaryKeys':{k:len(v) for k,v in dictionaries.items()},
                  'missingReferences':missing,'missingInDictionary':parity},ensure_ascii=False,indent=2))
raise SystemExit(1 if any(missing.values()) or any(parity.values()) else 0)
