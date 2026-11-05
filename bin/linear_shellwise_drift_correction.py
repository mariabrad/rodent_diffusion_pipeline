#!/usr/bin/env fslpython

# Remove temporal signal drift from diffusion MRI data on a voxelwise basis.
#
# Volumes are grouped according to their b-value (after optional rounding into
# approximate shells), and each b-value shell is detrended independently.
# This means that b0 volumes are detrended as their own group, separately from
# the diffusion-weighted shells (e.g. b=1000, b=2000).
#
# For each voxel and shell, a polynomial trend (linear by default) is fitted
# across the volumes belonging to that shell and removed. The original mean
# signal within that shell is then added back, so the mean signal level of
# each shell is preserved.
#
# note: The diffusion data are NOT normalised to the b0 signal, and the b0
# volumes are NOT used to normalise the diffusion-weighted shells. The
# normalise() function below is only used to scale the polynomial regressors
# in the detrending design matrix; it is not applied to the diffusion signal.
#
# Inputs:
#   datfile   input 4D diffusion data
#   bfile     b-values
#   ofile     output detrended data

import numpy as np
import nibabel as nib
import os.path as op
import argparse


def normalise(x,axis=0):
    return (x-np.mean(x,axis=axis))/np.std(x,axis)/np.sqrt(x.size)

def detrend(y,order=1):
    '''
       detrend data along second axis

    Parameters:
    y : array-like
    order : integer

    Returns:
    array-like
    '''
    x = np.linspace(0,1,y.shape[1])
    desmat = []
    for i in range(order+1):
        r = x**i
        if i>0:
            r = normalise(r)
        desmat.append(r.flatten())
    desmat = np.asarray(desmat).T
    beta = np.linalg.pinv(desmat)@y.T
    yc   = y - (desmat@beta).T + np.mean(y,axis=1)[:,None]

    return yc


def main():
    p = argparse.ArgumentParser(description='Detrend DWI data')

    p.add_argument('-d','--data',
                  required=True,type=str,metavar='VOLUME',
                  help='input data')
    p.add_argument('-b','--bval',
                   required=True,type=str,metavar='<str>',
                   help='bvals text file')
    p.add_argument('-o','--output',
                   required=True,type=str,metavar='VOLUME',
                   help='output data')
    p.add_argument('--approx',required=False,default=200,
                   help='range of equal bvals (default=200)') # Changed from 5
    p.add_argument('--order',required=False,default=1,
                   help='polynomial order')

    args = p.parse_args()

    # Load data
    filename = op.expandvars(args.data)
    imobj    = nib.load(filename,mmap=False)
    im       = imobj.get_fdata().astype(float)
    b        = np.loadtxt(args.bval)

    # round bvalues
    if args.approx > 0:
        b = np.round(b/(2.0*args.approx))*args.approx


    # Reshape data
    y = im.reshape((-1,im.shape[3]))

    # Loop over separate shells
    ub = np.unique(b)

    print('Processing shell (bval):')
    for bval in ub:
        print(2*bval)
        dwi = y[:,b==bval].copy()
        dwi = detrend(dwi)
        y[:,b==bval] = dwi.copy()


    im = y.reshape(im.shape)

    # Save new image
    newhdr = imobj.header.copy()
    newobj = nib.nifti1.Nifti1Image(im, None, header=newhdr)
    nib.save(newobj,args.output)



if __name__ == '__main__':
    main()
