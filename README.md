# Pipe Layout Backend (Windows + RTX 3090)

FastAPI backend for pipe detection from 3D point clouds.
Uses Open3D + PyTorch CUDA on Windows GPU.

## Stack
- Python 3.11
- FastAPI + Uvicorn
- Open3D
- PyTorch (CUDA)

## Local setup (Windows PowerShell)

```powershell
cd C:\pipe-layout-backend
py -3.11 -m venv .venv
C:\pipe-layout-backend\.venv\Scripts\python.exe -m pip install --upgrade pip
C:\pipe-layout-backend\.venv\Scripts\python.exe -m pip install -r requirements.txt
