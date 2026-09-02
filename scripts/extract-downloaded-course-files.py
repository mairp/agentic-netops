import csv
import html
import os
import re
import shutil
import subprocess
import zipfile
from pathlib import Path
from xml.etree import ElementTree as ET

ROOT = Path("/root/ai-champion")
SOURCE = ROOT / "course-files"
OUT = ROOT / "course-file-extracts"

NS = {
    "w": "http://schemas.openxmlformats.org/wordprocessingml/2006/main",
    "a": "http://schemas.openxmlformats.org/drawingml/2006/main",
    "r": "http://schemas.openxmlformats.org/officeDocument/2006/relationships",
    "main": "http://schemas.openxmlformats.org/spreadsheetml/2006/main",
    "rel": "http://schemas.openxmlformats.org/package/2006/relationships",
}


def safe_member_path(base: Path, member: str) -> Path:
    target = (base / member).resolve()
    if not str(target).startswith(str(base.resolve())):
        raise ValueError(f"Unsafe zip path: {member}")
    return target


def slug(value: str) -> str:
    return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-") or "file"


def para_text(paragraph) -> str:
    parts = []
    for node in paragraph.iter():
        if node.tag == f"{{{NS['w']}}}t":
            parts.append(node.text or "")
        elif node.tag == f"{{{NS['w']}}}tab":
            parts.append("\t")
        elif node.tag == f"{{{NS['w']}}}br":
            parts.append("\n")
    return "".join(parts).strip()


def extract_docx(path: Path) -> Path:
    destination = OUT / f"{path.stem}.md"
    with zipfile.ZipFile(path) as archive:
        xml = archive.read("word/document.xml")
    root = ET.fromstring(xml)
    blocks = [f"# {path.name}", ""]
    for element in root.iter():
        if element.tag == f"{{{NS['w']}}}p":
            text = para_text(element)
            if text:
                blocks.append(text)
                blocks.append("")
    destination.write_text("\n".join(blocks).strip() + "\n", encoding="utf-8")
    return destination


def extract_pdf(path: Path) -> Path:
    destination = OUT / f"{path.stem}.txt"
    result = subprocess.run(
        ["pdftotext", "-layout", str(path), "-"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    destination.write_bytes(result.stdout)
    return destination


def extract_nested_pdf(path: Path) -> Path:
    relative = path.relative_to(OUT)
    destination = OUT / "text-from-nested-pdfs" / relative.with_suffix(".txt")
    destination.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        ["pdftotext", "-layout", str(path), "-"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    destination.write_bytes(result.stdout)
    return destination


def col_index(cell_ref: str) -> int:
    letters = re.match(r"[A-Z]+", cell_ref or "")
    if not letters:
        return 0
    total = 0
    for char in letters.group(0):
        total = total * 26 + (ord(char) - ord("A") + 1)
    return total - 1


def read_shared_strings(archive: zipfile.ZipFile):
    try:
        root = ET.fromstring(archive.read("xl/sharedStrings.xml"))
    except KeyError:
        return []
    values = []
    for item in root.findall("main:si", NS):
        values.append("".join(text.text or "" for text in item.findall(".//main:t", NS)))
    return values


def worksheet_paths(archive: zipfile.ZipFile):
    workbook = ET.fromstring(archive.read("xl/workbook.xml"))
    rels = ET.fromstring(archive.read("xl/_rels/workbook.xml.rels"))
    rel_by_id = {rel.attrib["Id"]: rel.attrib["Target"] for rel in rels.findall("rel:Relationship", NS)}
    sheets = []
    for sheet in workbook.findall("main:sheets/main:sheet", NS):
        rel_id = sheet.attrib.get(f"{{{NS['r']}}}id")
        target = rel_by_id.get(rel_id, "").lstrip("/")
        if target and not target.startswith("xl/"):
            target = f"xl/{target}"
        sheets.append((sheet.attrib.get("name", "Sheet"), target))
    return sheets


def cell_value(cell, shared_strings):
    typ = cell.attrib.get("t")
    value = cell.find("main:v", NS)
    if typ == "inlineStr":
        return "".join(text.text or "" for text in cell.findall(".//main:t", NS))
    if value is None:
        return ""
    raw = value.text or ""
    if typ == "s":
        try:
            return shared_strings[int(raw)]
        except (ValueError, IndexError):
            return raw
    return raw


def extract_xlsx(path: Path):
    outputs = []
    with zipfile.ZipFile(path) as archive:
        shared_strings = read_shared_strings(archive)
        for sheet_name, sheet_path in worksheet_paths(archive):
            if not sheet_path:
                continue
            destination = OUT / f"{path.stem}-{slug(sheet_name)}.csv"
            root = ET.fromstring(archive.read(sheet_path))
            with destination.open("w", newline="", encoding="utf-8") as handle:
                writer = csv.writer(handle)
                for row in root.findall(".//main:sheetData/main:row", NS):
                    values = []
                    for cell in row.findall("main:c", NS):
                        index = col_index(cell.attrib.get("r", ""))
                        while len(values) < index:
                            values.append("")
                        values.append(cell_value(cell, shared_strings))
                    writer.writerow(values)
            outputs.append(destination)
    return outputs


def extract_zip(path: Path):
    base = OUT / path.stem
    base.mkdir(parents=True, exist_ok=True)
    extracted = []
    with zipfile.ZipFile(path) as archive:
        for member in archive.infolist():
            if member.is_dir():
                continue
            destination = safe_member_path(base, member.filename)
            destination.parent.mkdir(parents=True, exist_ok=True)
            with archive.open(member) as src, destination.open("wb") as dst:
                shutil.copyfileobj(src, dst)
            extracted.append(destination)
    return extracted


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    extracted = []
    for file_path in sorted(SOURCE.iterdir()):
        suffix = file_path.suffix.lower()
        if suffix == ".pdf":
            extracted.append(extract_pdf(file_path))
        elif suffix == ".docx":
            extracted.append(extract_docx(file_path))
        elif suffix == ".xlsx":
            extracted.extend(extract_xlsx(file_path))
        elif suffix == ".zip":
            extracted.extend(extract_zip(file_path))
        elif suffix in {".skill", ".txt", ".md", ".csv"}:
            destination = OUT / file_path.name
            shutil.copyfile(file_path, destination)
            extracted.append(destination)

    for nested_pdf in sorted(OUT.glob("AI-Campus-Second-Brain-Starter-Vault/**/*.pdf")):
        extracted.append(extract_nested_pdf(nested_pdf))

    index = ["# Extracted Downloaded Course Files", "", "Source folder: `/root/ai-champion/course-files`", ""]
    for item in extracted:
        index.append(f"- `{item.relative_to(ROOT)}` ({item.stat().st_size} bytes)")
    (OUT / "course-file-extracts-index.md").write_text("\n".join(index) + "\n", encoding="utf-8")
    print(f"Extracted {len(extracted)} files into {OUT}")


if __name__ == "__main__":
    main()
