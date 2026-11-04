"""Run portable async recovery checks without affecting other Qt imports."""
from pathlib import Path
import subprocess
import sys
import unittest

class PortableAsyncRecovery(unittest.TestCase):
    def test_async_recovery_contracts(self):
        path=Path(__file__).with_name('portable_async_recovery_contracts.py')
        result=subprocess.run([sys.executable,str(path)],capture_output=True,text=True,timeout=30)
        self.assertEqual(0,result.returncode,result.stdout+result.stderr)

if __name__=='__main__':unittest.main()
