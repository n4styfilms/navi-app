"""Exercise the real input domain and private-file store across fresh JVM processes."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


class VehicleJavaTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        suffix = '.exe' if os.name == 'nt' else ''
        home = os.environ.get('JAVA_HOME')
        javac = str(Path(home) / 'bin' / ('javac' + suffix)) if home else shutil.which('javac')
        cls.java = str(Path(home) / 'bin' / ('java' + suffix)) if home else shutil.which('java')
        if not javac or not cls.java:
            raise unittest.SkipTest('JDK unavailable; set JAVA_HOME')
        cls.root = Path(__file__).resolve().parents[3]
        cls.directory = tempfile.TemporaryDirectory(prefix='navi-vehicle-')
        cls.addClassCleanup(cls.directory.cleanup)
        domain = cls.root / 'android/app/src/main/java/app/organicmaps/fuel'
        sources = [domain / name for name in ('VehicleProfile.java', 'VehicleInput.java', 'VehicleStore.java')]
        built = subprocess.run([javac, '-d', cls.directory.name, *(str(p) for p in sources),
                                str(Path(__file__).with_name('VehicleProbe.java'))],
                               capture_output=True, text=True, timeout=60)
        if built.returncode:
            raise AssertionError(built.stdout + built.stderr)

    def run_probe(self, *args):
        result = subprocess.run([self.java, '-cp', self.directory.name, 'VehicleProbe', *map(str,args)],
                                capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout.strip().split('\t')

    def test_shared_input_cases(self):
        cases = json.loads((self.root / 'testing/private/vehicle-input-cases.json').read_text(encoding='utf-8'))
        cases.append({'name':'overflow', 'numbers':['9'*400,'1.8',''], 'errors':['WLTP']})
        for case in cases:
            with self.subTest(case=case['name']):
                inputs = [case.get(key,default) for key,default in
                          [('make','Test'),('model','Car'),('engine','Motor'),('year','2020'),('fuel','DIESEL')]]
                fields = self.run_probe('parse', *inputs, *case['numbers'])
                if 'errors' in case:
                    self.assertEqual(fields[0], 'ERROR')
                    self.assertEqual(set(fields[1:]), set(case['errors']))
                else:
                    self.assertEqual(fields[0], 'READY')
                    self.assertEqual([float(x) if x!='null' else None for x in fields[6:]], case['expected'])

    def test_store_restart_invalid_write_schema_and_delete(self):
        with tempfile.TemporaryDirectory(prefix='navi-profile-') as directory:
            file = Path(directory) / 'vehicle.properties'
            self.assertEqual(self.run_probe('load',file), ['EMPTY'])
            values = ['Marke','Modell','2.0 TDI','2020','DIESEL','6,2','1,80','7,25']
            self.assertEqual(self.run_probe('save',file,*values), ['SAVED'])
            # Each invocation creates a fresh JVM: persistence cannot be a static cache.
            fields = self.run_probe('load',file)
            self.assertEqual(fields[:6], ['READY',*values[:5]])
            self.assertEqual([float(x) for x in fields[6:]], [6.2,1.8,7.25])
            original = file.read_bytes()
            self.assertEqual(self.run_probe('invalid',file), ['REJECTED'])
            self.assertEqual(file.read_bytes(), original)
            values[-1] = ''
            self.assertEqual(self.run_probe('save',file,*values), ['SAVED'])
            self.assertEqual(self.run_probe('load',file)[-1], 'null')
            file.write_text('schema=99\n',encoding='ascii')
            self.assertEqual(self.run_probe('load',file), ['UNSUPPORTED_SCHEMA'])
            self.assertEqual(file.read_text(encoding='ascii'),'schema=99\n')
            file.write_text('schema=1\nwltp=NaN\n',encoding='ascii')
            self.assertEqual(self.run_probe('load',file), ['INVALID'])
            self.assertEqual(self.run_probe('delete',file), ['DELETED'])
            self.assertEqual(self.run_probe('load',file), ['EMPTY'])
            self.assertFalse(file.exists())
            self.assertFalse(file.with_name(file.name+'.new').exists())
