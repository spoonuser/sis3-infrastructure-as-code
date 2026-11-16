from pathlib import Path

def test_required_project_files_exist():
    root = Path(__file__).resolve().parents[1]
    required = [
        "README.md",
        "app/app.py",
        "app/Dockerfile",
        "app/requirements.txt",
        "infrastructure/template.yaml",
    ]
    missing = [name for name in required if not (root / name).exists()]
    assert not missing, f"Missing files: {missing}"
