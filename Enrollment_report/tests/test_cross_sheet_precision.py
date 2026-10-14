import unittest
from cross_sheet_precision import paired_values_match
class PrecisionTests(unittest.TestCase):
    def test_observed_native_precision(self):
        self.assertTrue(paired_values_match('CASELOAD',1.0011717677116394e-8,0))
        self.assertTrue(paired_values_match('DISENROLLMENT',0,-1.0000011929633956e-10))
    def test_real_member_difference_rejected(self):
        self.assertFalse(paired_values_match('CASELOAD',1,0))
        self.assertFalse(paired_values_match('ENROLLMENT',1,0))
    def test_integer_counts_stay_exact(self):
        self.assertFalse(paired_values_match('DISENROLLMENT',1e-8,0))
    def test_larger_ratio_difference_rejected(self):
        self.assertFalse(paired_values_match('CASELOAD',0,1e-8))
if __name__=='__main__':unittest.main()
