import argparse
import json
from pathlib import Path

from pypdf import PdfReader


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--pdf", required=True, type=Path)
    parser.add_argument("--output-directory", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    args = parser.parse_args()

    args.output_directory.mkdir(parents=True, exist_ok=True)
    extracted = []
    reader = PdfReader(str(args.pdf))
    for page_number, page in enumerate(reader.pages, start=1):
        for image_number, image in enumerate(page.images, start=1):
            width, height = image.image.size
            aspect_ratio = width / height
            if width < 160 or height < 160 or aspect_ratio > 2.8 or aspect_ratio < 0.36:
                continue
            extension = Path(image.name).suffix.lower()
            if extension not in {".jpg", ".jpeg", ".png"}:
                raise ValueError(
                    f"Unsupported embedded image format '{extension}' "
                    f"on PDF page {page_number}."
                )
            filename = f"page-{page_number:04d}-image-{image_number:02d}{extension}"
            output_path = args.output_directory / filename
            output_path.write_bytes(image.data)
            extracted.append({"page": page_number, "filename": filename})

    args.manifest.parent.mkdir(parents=True, exist_ok=True)
    args.manifest.write_text(json.dumps({"images": extracted}), encoding="utf-8")


if __name__ == "__main__":
    main()
