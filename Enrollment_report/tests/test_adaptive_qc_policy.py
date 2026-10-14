import sys,unittest
from pathlib import Path
from decimal import Decimal
sys.path.insert(0,str(Path(__file__).parent.parent/'src/linux'))
from adaptive_qc_policy import thresholds

class AdaptivePolicyTests(unittest.TestCase):
    def test_activation_boundary_and_business_floors(self):
        self.assertEqual(thresholds([Decimal(100)]*7,50,100),(Decimal(50),Decimal(100),False))
        self.assertEqual(thresholds([Decimal(100)]*8,50,100),(Decimal(100),Decimal(100),True))
        self.assertEqual(thresholds([Decimal(0)]*8,15000,30000),(Decimal(15000),Decimal(30000),True))
    def test_sample_standard_deviation(self):
        values=list(map(Decimal,range(8)))
        average=Decimal('3.5');sd=Decimal(6).sqrt()
        warning,blocking,active=thresholds(values,0,0)
        self.assertEqual(warning,average+2*sd)
        self.assertEqual(blocking,average+3*sd)
        self.assertTrue(active)

if __name__=='__main__':unittest.main()
