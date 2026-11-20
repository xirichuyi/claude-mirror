"""Exercise the CLI boundary using real Winc decoders, without a server or UI."""
import json
import os
from pathlib import Path
import subprocess
import tempfile
import zipfile

root = Path(__file__).resolve().parents[4]
helper = Path(os.environ.get('WINC_PREVIEW_HELPER', str(root / 'macos/Helpers/WincPreview/target/release/winc-preview-bridge')))
with tempfile.TemporaryDirectory() as directory:
    folder = Path(directory)
    def render(path):
        output = folder / (path.name + '-output')
        subprocess.run([str(helper), str(path), str(output)], check=True)
        return json.loads((output / 'result.json').read_text()), output

    csv = folder / 'quoted.csv'
    csv.write_text('name,note\n"a,b","line\nnext"\n')
    result, _ = render(csv)
    assert result['sheets'][0]['rows'][1] == ['a,b', 'line\nnext']
    assert result['sheets'][0]['labels'] == ['A', 'B']

    svg = folder / 'shape.svg'
    svg.write_text('<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 40 20"><rect width="40" height="20" fill="red"/></svg>')
    result, output = render(svg)
    assert result['kind'] == 'image'
    assert (output / 'image.png').read_bytes().startswith(b'\x89PNG')

    jpeg = root / 'vendor/winc-preview/crates/winc-preview/testdata/red-8x8.jpg'
    result, _ = render(jpeg)
    assert result['width'] == 8 and result['height'] == 8

    markdown = folder / 'note.md'
    markdown.write_text('# Heading\n\n**bold** and [link](docs/)\n\n- [x] done\n')
    result, _ = render(markdown)
    assert result['blocks'][0]['kind'] == 'heading'
    assert any(run['flags'] & 1 for run in result['blocks'][1]['inline']['runs'])
    assert result['blocks'][2]['items'][0]['task'] is True

    workbook = folder / 'book.xlsx'
    with zipfile.ZipFile(workbook, 'w', zipfile.ZIP_DEFLATED) as archive:
        archive.writestr('xl/workbook.xml', '<workbook xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships"><sheets><sheet name="One" sheetId="1" r:id="rId1"/><sheet name="Two" sheetId="2" r:id="rId2"/></sheets></workbook>')
        archive.writestr('xl/_rels/workbook.xml.rels', '<Relationships><Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet1.xml"/><Relationship Id="rId2" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" Target="worksheets/sheet2.xml"/></Relationships>')
        archive.writestr('xl/worksheets/sheet1.xml', '<worksheet><sheetData><row r="1"><c r="A1" t="inlineStr"><is><t>Hello</t></is></c><c r="B1"><v>42</v></c></row></sheetData></worksheet>')
        archive.writestr('xl/worksheets/sheet2.xml', '<worksheet><sheetData><row r="1"><c r="A1"><v>7</v></c></row></sheetData></worksheet>')
    result, _ = render(workbook)
    assert [sheet['name'] for sheet in result['sheets']] == ['One', 'Two']
    assert result['sheets'][0]['rows'][0] == ['Hello', '42']
print('Winc bridge: CSV, SVG, JPEG, Markdown, multi-sheet XLSX passed')
