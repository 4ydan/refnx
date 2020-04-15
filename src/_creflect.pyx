# cython: language_level=3, boundscheck=False
"""
    *Calculates the specular (Neutron or X-ray) reflectivity from a stratified
    series of layers.

The refnx code is distributed under the following license:

Copyright (c) 2015 A. R. J. Nelson, Australian Nuclear Science and Technology Organisation

Permission to use and redistribute the source code or binary forms of this
software and its documentation, with or without modification is hereby
granted provided that the above notice of copyright, these terms of use,
and the disclaimer of warranty below appear in the source code and
documentation, and that none of the names of above institutions or
authors appear in advertising or endorsement of works derived from this
software without specific prior written permission from all parties.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.  IN NO EVENT SHALL
THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THIS SOFTWARE.

"""
from multiprocessing import cpu_count
import numpy as np

cimport numpy as cnp
cimport cython

cdef extern from "refcalc.h" nogil:
    void reflect(int numcoefs, const double *coefP, int npoints, double *yP,
                 const double *xP)
    void reflectMT(int numcoefs, const double *coefP, int npoints, double *yP,
                   const double *xP, int threads)

DTYPE = np.float64
ctypedef cnp.float64_t DTYPE_t


# figure out CPU count
NCPU = cpu_count()


@cython.boundscheck(False)
@cython.cdivision(True)
cpdef cnp.ndarray abeles(cnp.ndarray x,
                         double[:, :] w,
                         double scale=1.0,
                         double bkg=0.,
                         int threads=-1):

    if w.shape[1] != 4 or w.shape[0] < 2:
        raise ValueError("Layer parameters for _creflect must be an array of"
                         " shape (>2, 4)")
    if x.dtype != np.float64:
        raise ValueError("Q values for _creflect must be np.float64")
    cdef:
        int nlayers = w.shape[0] - 2
        int npoints = x.size
        cnp.ndarray[DTYPE_t, ndim=1] coefs = np.empty(4*nlayers + 8,
                                                      DTYPE)
        double[::1] coefs_view = coefs
        cnp.ndarray y = np.empty_like(x, DTYPE)

    if not x.flags['C_CONTIGUOUS']:
        x = np.ascontiguousarray(x, dtype=DTYPE)

    if threads == -1:
        threads = NCPU
    elif threads == 0:
        threads = 1

    with nogil:
        coefs_view[0] = nlayers
        coefs_view[1] = scale
        coefs_view[2:4] = w[0, 1: 3]
        coefs_view[4: 6] = w[-1, 1: 3]
        coefs_view[6] = bkg
        coefs_view[7] = w[-1, 3]
        if nlayers:
            coefs_view[8::4] = w[1:-1, 0]
            coefs_view[9::4] = w[1:-1, 1]
            coefs_view[10::4] = w[1:-1, 2]
            coefs_view[11::4] = w[1:-1, 3]

        if threads > 1:
            reflectMT(4*nlayers + 8, <const double*>coefs.data, npoints,
                      <double*>y.data, <const double*>x.data, threads)
        else:
            reflect(4*nlayers + 8, <const double*>coefs.data, npoints,
                    <double*>y.data, <const double*>x.data)

    return y


cpdef _contract_by_area(cnp.ndarray[cnp.float64_t, ndim=2] slabs, dA=0.5):
    newslabs = np.copy(slabs)[::-1]

    cdef:
        double [:, :] newslabs_view = newslabs
        double [:] d = newslabs_view[:, 0]
        double [:] rho = newslabs_view[:, 1]
        double [:] irho = newslabs_view[:, 2]
        double [:] sigma = newslabs[:, 3]
        double [:] vfsolv = newslabs[:, 4]

        size_t n = np.size(d, 0)
        size_t i, newi
        double dz, rhoarea, irhoarea, vfsolvarea, rholo, rhohi, irholo, irhohi
        double da = float(dA)

    with nogil:
        i = 1
        newi = 1 # skip the substrate

        while i < n:
            # Get ready for the next layer
            # Accumulation of the first row happens in the inner loop
            dz = rhoarea = irhoarea = vfsolvarea = 0.
            rholo = rhohi = rho[i]
            irholo = irhohi = irho[i]

            # Accumulate slices into layer
            while True:
                # Accumulate next slice
                dz += d[i]
                rhoarea += d[i] * rho[i]
                irhoarea += d[i] * irho[i]
                vfsolvarea += d[i] * vfsolv[i]

                i += 1
                # If no more slices or sigma != 0, break immediately
                if i == n or sigma[i - 1] != 0.:
                    break

                # If next slice won't fit, break
                if rho[i] < rholo:
                    rholo = rho[i]
                if rho[i] > rhohi:
                    rhohi = rho[i]
                if (rhohi - rholo) * (dz + d[i]) > da:
                    break

                if irho[i] < irholo:
                    irholo = irho[i]
                if irho[i] > irhohi:
                    irhohi = irho[i]
                if (irhohi - irholo) * (dz + d[i]) > da:
                    break

            # Save the layer
            d[newi] = dz
            if i == n:
                # printf("contract: adding final sld at %d\n",newi)
                # Last layer uses surface values
                rho[newi] = rho[n - 1]
                irho[newi] = irho[n - 1]
                vfsolv[newi] = vfsolv[n - 1]
            else:
                # Middle layers uses average values
                rho[newi] = rhoarea / dz
                irho[newi] = irhoarea / dz
                sigma[newi] = sigma[i - 1]
                vfsolv[newi] = vfsolvarea / dz
            # First layer uses substrate values
            newi += 1

    return newslabs[:newi][::-1]
