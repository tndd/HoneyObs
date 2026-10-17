"""開発バンドルだけをSpotlight索引の対象外へ置く。導入済みアプリの場所は変えない。"""
from pathlib import Path


def build_app(root: Path) -> Path:
    app = root / 'build/Applications.noindex/HoneyObs.app'
    if not app.is_absolute() or app.resolve() != app:
        raise ValueError('開発アプリの保存先にsymlinkや相対パスは使えません: ' + str(app))
    return app


if __name__ == '__main__':
    print(build_app(Path(__file__).resolve().parent.parent))
