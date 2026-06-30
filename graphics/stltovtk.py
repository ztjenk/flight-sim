#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 Zachary Jenkins

"""
stl_to_triangulated_vtk.py

Convert an STL (ASCII or binary) to a triangulated VTK mesh.

- Default output: legacy .vtk (ASCII). Use --binary for binary legacy.
- Use --vtp to write XML .vtp instead.
- Optional --clean to merge duplicate points (set --tolerance).

Usage examples:
  python stl_to_triangulated_vtk.py input.stl output.vtk
  python stl_to_triangulated_vtk.py input.stl output.vtk --binary
  python stl_to_triangulated_vtk.py input.stl output.vtp --vtp
  python stl_to_triangulated_vtk.py input.stl output.vtk --clean --tolerance 1e-6
"""

import argparse
import sys

def main():
    parser = argparse.ArgumentParser(description="Convert STL to triangulated VTK POLYDATA.")
    parser.add_argument("input", help="Input STL file (ASCII or binary).")
    parser.add_argument("output", help="Output .vtk (legacy) or .vtp (XML if --vtp).")
    parser.add_argument("--binary", action="store_true", help="Write binary (legacy .vtk only).")
    parser.add_argument("--vtp", action="store_true", help="Write XML .vtp instead of legacy .vtk.")
    parser.add_argument("--clean", action="store_true",
                        help="Run vtkCleanPolyData to merge duplicate/unused points.")
    parser.add_argument("--tolerance", type=float, default=0.0,
                        help="Cleaning tolerance for --clean (0 means exact duplicates only).")
    args = parser.parse_args()

    try:
        import vtk
    except Exception:
        print("This script requires VTK. Install with:\n  pip install vtk", file=sys.stderr)
        sys.exit(1)

    # ---- Read STL ----
    reader = vtk.vtkSTLReader()
    reader.SetFileName(args.input)
    reader.Update()

    # Upstream port for optional filters
    last_port = reader.GetOutputPort()

    # ---- Optional clean (dedupe points, remove degenerate cells) ----
    if args.clean:
        cleaner = vtk.vtkCleanPolyData()
        cleaner.SetInputConnection(last_port)
        cleaner.PointMergingOn()
        cleaner.SetTolerance(args.tolerance)
        cleaner.Update()
        last_port = cleaner.GetOutputPort()

    # ---- Force triangulation ----
    tri = vtk.vtkTriangleFilter()
    tri.SetInputConnection(last_port)
    tri.PassVertsOff()
    tri.PassLinesOff()
    tri.Update()

    final_poly = tri.GetOutput()

    # ---- Version-agnostic sanity check: ensure only triangles remain ----
    # 1) No verts/lines
    has_verts = final_poly.GetNumberOfVerts() > 0
    has_lines = final_poly.GetNumberOfLines() > 0

    # 2) All polys have exactly 3 ids
    all_tris = True
    polys = final_poly.GetPolys()
    ids = vtk.vtkIdList()
    polys.InitTraversal()
    while polys.GetNextCell(ids):
        if ids.GetNumberOfIds() != 3:
            all_tris = False
            break

    if has_verts or has_lines or not all_tris:
        # Fallback: extract surface polys then triangulate again
        geom = vtk.vtkGeometryFilter()
        geom.SetInputData(final_poly)
        geom.Update()

        tri2 = vtk.vtkTriangleFilter()
        tri2.SetInputConnection(geom.GetOutputPort())
        tri2.PassVertsOff()
        tri2.PassLinesOff()
        tri2.Update()

        final_poly = tri2.GetOutput()

        # Re-check
        has_verts = final_poly.GetNumberOfVerts() > 0
        has_lines = final_poly.GetNumberOfLines() > 0
        all_tris = True
        polys = final_poly.GetPolys()
        ids = vtk.vtkIdList()
        polys.InitTraversal()
        while polys.GetNextCell(ids):
            if ids.GetNumberOfIds() != 3:
                all_tris = False
                break

        if has_verts or has_lines or not all_tris:
            print("Error: mesh still contains non-triangle cells after processing.", file=sys.stderr)
            sys.exit(2)

    # ---- Write output ----
    # Decide by flag or extension
    out_lower = args.output.lower()
    write_vtp = args.vtp or out_lower.endswith(".vtp")

    if write_vtp:
        # XML PolyData (.vtp)
        writer = vtk.vtkXMLPolyDataWriter()
        out_name = args.output if out_lower.endswith(".vtp") else (args.output + ".vtp")
        writer.SetFileName(out_name)
        writer.SetInputData(final_poly)
        # Binary (appended) keeps files compact; change to SetDataModeToAscii() if desired
        writer.SetDataModeToBinary()
        ok = writer.Write()
    else:
        # Legacy PolyData (.vtk)
        writer = vtk.vtkPolyDataWriter()
        out_name = args.output if out_lower.endswith(".vtk") else (args.output + ".vtk")
        writer.SetFileName(out_name)
        writer.SetInputData(final_poly)
        if args.binary:
            writer.SetFileTypeToBinary()
        else:
            writer.SetFileTypeToASCII()
        ok = writer.Write()

    if not ok:
        print("Failed to write output.", file=sys.stderr)
        sys.exit(1)

    # ---- Report ----
    n_pts = final_poly.GetNumberOfPoints()
    n_tris = final_poly.GetNumberOfPolys()
    print(f"Wrote {out_name}")
    print(f"Points: {n_pts}")
    print(f"Triangles: {n_tris}")
    if not write_vtp:
        print("Legacy VTK note: In the POLYGONS header, the second number equals 4 × (#triangles).")

if __name__ == "__main__":
    main()




    