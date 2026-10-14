"""Numerical equality only, far below report display or business thresholds.

Native SAS XLSX preserves fractional caseload means and independently summed
ratios. Different summation orders can differ at approximately 1e-8 members
and 1e-10 in the ratio. Enrollment/disenrollment counts remain exact integers.
"""
COUNT_PRECISION=1e-7
RATIO_PRECISION=1e-9
def paired_values_match(section,count_difference,ratio_difference):
    count_bound=COUNT_PRECISION if section=='CASELOAD' else 0
    return abs(count_difference)<=count_bound and abs(ratio_difference)<=RATIO_PRECISION
