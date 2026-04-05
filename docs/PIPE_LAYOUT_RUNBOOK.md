# Pipe Layout — runbook

## Windows PC (backend)

- **Backend folder:** `C:\pipe-layout-backend` (FastAPI / uvicorn app).
- **LAN URL for phones:** `http://192.168.4.70:8000` — use this in the Flutter app **Backend URL** field (not `127.0.0.1` from the phone).
- **Start server:** from the Flutter repo, run `scripts/run_backend.ps1`, or manually activate `.venv` under `C:\pipe-layout-backend` and run:
  `python -m uvicorn app:app --host 0.0.0.0 --port 8000`
- Confirm with `http://192.168.4.70:8000/health` from another device on the same Wi‑Fi.

## Flutter app (Mac + iPhone)

- Default backend hint in-app matches this PC: `http://192.168.4.70:8000`.
- **Apple Developer enrollment pending — use USB/Xcode until TestFlight** (install and debug via cable and Xcode; distribution via Archive when the account is ready).

### iOS release build (Mac)

- From repo root: `scripts/run_ios_release.sh` (see comments there for `chmod +x`).
- Then open `ios/Runner.xcworkspace`, select device/team, **Product → Run** or **Archive**.

## Quick checks

| Check              | Action                                      |
| ------------------ | ------------------------------------------- |
| Phone → PC         | Same Wi‑Fi; firewall allows port **8000**   |
| Backend URL        | `http://192.168.4.70:8000`                  |
| Health             | **Health Check** in app or GET `/health`    |
