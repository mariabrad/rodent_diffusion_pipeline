#!/usr/bin/env python3
# Apply B * inv(A) to a bvecs file (3 rows x N columns).
# A = data orientation, B = bvec orientation (Cristiana).
import sys
import numpy as np

A = np.array([[1, 0,  0],    # x -z y
              [0, 0, -1],
              [0, 1,  0]])
B = np.array([[0,  0, 1],    # z -y x
              [0, -1, 0],
              [1,  0, 0]])

M = B @ np.linalg.inv(A)
print("B * inv(A) =\n", np.round(M).astype(int))

bvecs = np.loadtxt(sys.argv[1])          # 3 x N
out = M @ bvecs
np.savetxt(sys.argv[2], out, fmt="%.10g")
