# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Zachary Jenkins

import os
import sys
import vtk

def read_polydata(path):
    ext = os.path.splitext(path)[1].lower()
    if ext == ".vtp":
        r = vtk.vtkXMLPolyDataReader()
    else:
        # Handles legacy .vtk POLYDATA
        r = vtk.vtkGenericDataObjectReader()
    r.SetFileName(path)
    r.Update()
    data = r.GetOutput()
    if not isinstance(data, vtk.vtkPolyData):
        data = vtk.vtkPolyData.SafeDownCast(data)
    return data

def polys_are_all_triangles(polydata: vtk.vtkPolyData) -> bool:
    """Return True iff every polygon cell has exactly 3 point ids."""
    polys = polydata.GetPolys()
    if polys is None:
        return False
    ids = vtk.vtkIdList()
    polys.InitTraversal()
    while polys.GetNextCell(ids):
        if ids.GetNumberOfIds() != 3:
            return False
    # If there were no polys at all, caller decides (could be only strips)
    return True

def is_triangulated_mesh(vtk_file_path: str, accept_strips: bool = True) -> bool:
    """
    Checks if a VTK/VTP file contains a triangulated surface mesh.
    - Triangulated means: all POLYGONS are triangles.
    - If accept_strips=True, TRIANGLE_STRIPS also count as triangulated.
    """
    pd = read_polydata(vtk_file_path)
    if pd is None:
        print("Error: Could not read file or it is not VTK PolyData.")
        return False

    n_polys  = pd.GetNumberOfPolys()
    n_strips = pd.GetNumberOfStrips()

    # If there are polygons, require they all be triangles
    all_tris = polys_are_all_triangles(pd) if n_polys > 0 else True

    if not all_tris:
        return False

    # If there are zero polygons but there are triangle strips, accept if allowed
    if n_polys == 0 and n_strips > 0:
        return accept_strips

    # If there are neither polys nor strips, it's not a surface mesh
    if n_polys == 0 and n_strips == 0:
        print("Warning: No surface cells (POLYGONS/STRIPS) found.")
        return False

    # Otherwise: polygons are all triangles; strips (if any) ok if accepted
    return accept_strips or n_strips == 0

if __name__ == "__main__":
    path = sys.argv[1] if len(sys.argv) > 1 else "F16test.vtk"
    if is_triangulated_mesh(path, accept_strips=True):
        print("The VTK file contains a triangulated mesh.")
    else:
        print("The VTK file does not contain a pure triangulated mesh.")
