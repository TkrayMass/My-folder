"""Run offline tests without generation, publication, or email."""
import sys, unittest, tempfile
from pathlib import Path
root = Path(__file__).resolve().parent.parent
for directory in ('src/research', 'src/linux', 'src/windows', 'tests'):
    sys.path.insert(0, str(root / directory))
(root / 'tests/Validation').mkdir(exist_ok=True)
tempfile.tempdir = str(root / 'tests/Validation')
suite = unittest.defaultTestLoader.discover(str(root / 'tests'), pattern='test_*.py')
result = unittest.TextTestRunner(verbosity=2).run(suite)
raise SystemExit(not result.wasSuccessful())
