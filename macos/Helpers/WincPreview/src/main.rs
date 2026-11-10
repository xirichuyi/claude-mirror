use std::{fs, path::Path};
use serde_json::{Value, json};
use winc_preview::{image, markdown, table};

fn main() {
    if let Err(error) = run() { eprintln!("{error}"); std::process::exit(1); }
}
fn run() -> Result<(), String> {
    let args: Vec<String> = std::env::args().collect();
    let path = Path::new(args.get(1).ok_or("missing input path")?);
    let output = Path::new(args.get(2).ok_or("missing output directory")?);
    fs::create_dir_all(output).map_err(|e| e.to_string())?;
    let result = if image::is_image(path) || image::is_svg(path) {
        let picture = if image::is_svg(path) {
            let text = fs::read_to_string(path).map_err(|e| e.to_string())?;
            winc_preview::svg::load(&text, None, None)?
        } else { image::load(path)? };
        let max = 1600.0_f64;
        let scale = (max / picture.width.max(picture.height) as f64).min(1.0);
        // SVG is rendered at pane resolution, including small icons.
        let scale = if image::is_svg(path) { max / picture.width.max(picture.height) as f64 } else { scale };
        let pixels = picture.render((picture.width as f64 * scale).round().max(1.0) as u32,
                                    (picture.height as f64 * scale).round().max(1.0) as u32);
        let file = fs::File::create(output.join("image.png")).map_err(|e| e.to_string())?;
        let mut encoder = png::Encoder::new(file, pixels.width, pixels.height);
        encoder.set_color(png::ColorType::Rgba); encoder.set_depth(png::BitDepth::Eight);
        encoder.write_header().map_err(|e| e.to_string())?.write_image_data(&pixels.rgba).map_err(|e| e.to_string())?;
        json!({"kind":"image", "width":picture.width, "height":picture.height, "format":picture.format, "missing":picture.missing()})
    } else if table::is_workbook(path) {
        let workbook = table::load_workbook(path)?;
        json!({"kind":"table", "sheets":workbook.sheets.iter().map(sheet).collect::<Vec<_>>()})
    } else if table::is_delimited(path) {
        let text = fs::read_to_string(path).map_err(|e| e.to_string())?;
        json!({"kind":"table", "sheets":[sheet(&table::read_delimited(&text, Some(path)))]})
    } else if markdown::is_markdown(path) {
        let text = fs::read_to_string(path).map_err(|e| e.to_string())?;
        let document = markdown::parse(&text);
        json!({"kind":"markdown", "blocks":document.blocks.iter().map(block).collect::<Vec<_>>()})
    } else { return Err("Winc 不支持预览此文件格式".into()); };
    fs::write(output.join("result.json"), result.to_string()).map_err(|e| e.to_string())
}
fn sheet(s: &table::Sheet) -> Value {
    json!({"name":s.name,"rows":s.rows,"columns":s.columns,"labels":(0..s.columns).map(table::column_name).collect::<Vec<_>>(),"truncated":s.truncated,
           "merges":s.merges.iter().map(|a| json!([a.top,a.left,a.bottom,a.right])).collect::<Vec<_>>()})
}
fn inline(i: &markdown::Inline) -> Value {
    let mut start = 0;
    let runs: Vec<Value> = i.runs.iter().map(|r| {
        let text = &i.text[start..r.end]; start = r.end;
        json!({"text":text,"flags":r.style.flags,"link":if r.style.link == 0 { None } else { i.links.get(r.style.link as usize-1) }})
    }).collect();
    json!({"text":i.text,"runs":runs,"images":i.images.iter().map(|image| json!({"url":image.url,"alt":image.alt})).collect::<Vec<_>>()})
}
fn block(b: &markdown::Block) -> Value {
    use markdown::Block::*;
    match b {
        Paragraph(i) => json!({"kind":"paragraph","inline":inline(i)}),
        Heading(level,i) => json!({"kind":"heading","level":level,"inline":inline(i)}),
        Code{lang,text,..} => json!({"kind":"code","language":lang,"text":text}),
        Quote(_,blocks) => json!({"kind":"quote","blocks":blocks.iter().map(block).collect::<Vec<_>>()}),
        List(start,items) => json!({"kind":"list","start":start,"items":items.iter().map(|i|json!({"task":i.task,"blocks":i.blocks.iter().map(block).collect::<Vec<_>>()})).collect::<Vec<_>>()}),
        Table(_,rows,header) => json!({"kind":"table","header":header,"rows":rows.iter().map(|r|r.iter().map(inline).collect::<Vec<_>>()).collect::<Vec<_>>()}),
        Math(text) => json!({"kind":"math","text":text}),
        Rule => json!({"kind":"rule"}),
        Footnote(label,blocks) => json!({"kind":"footnote","text":label,"blocks":blocks.iter().map(block).collect::<Vec<_>>()}),
        Details{open,summary,blocks} => json!({"kind":"details","open":open,"inline":inline(summary),"blocks":blocks.iter().map(block).collect::<Vec<_>>()}),
    }
}
