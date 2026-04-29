import xml.etree.ElementTree as ET


def extract_and_prefix(input_file, body_output, prefix, pos, euler=None):
    tree = ET.parse(input_file)
    root = tree.getroot()

    name_attrs = ["name", "joint", "body", "geom", "site", "mesh", "material", "texture"]

    for elem in root.iter():
        for attr in name_attrs:
            if attr in elem.attrib:
                elem.attrib[attr] = f"{prefix}_{elem.attrib[attr]}"

    worldbody = root.find("worldbody")
    source = worldbody if worldbody is not None else root

    # Wrap everything in a single root body
    wrapper_attrs = {"name": f"{prefix}_base", "pos": f"{pos[0]} {pos[1]} {pos[2]}"}
    if euler:
        wrapper_attrs["euler"] = f"{euler[0]} {euler[1]} {euler[2]}"

    wrapper = ET.Element("body", **wrapper_attrs)
    for child in source:
        wrapper.append(child)

    container = ET.Element("worldbody")
    container.append(wrapper)

    ET.indent(ET.ElementTree(container))
    ET.ElementTree(container).write(body_output)
    print(f"Body written: {body_output}")

    return root.find("asset")

def build_scene(robot_xml, robot_dir="meca_500", output_xml="model.xml"):
    asset1 = extract_and_prefix(robot_xml, f"{robot_dir}/meca_500_r1.xml", "r1", [-0.5, 0, 0])
    asset2 = extract_and_prefix(robot_xml, f"{robot_dir}/meca_500_r2.xml", "r2", [0, 0, 0])

    mujoco_el = ET.Element("mujoco", model="dual_meca_scene")

    combined_asset = ET.SubElement(mujoco_el, "asset")
    for asset in [asset1, asset2]:
        if asset is not None:
            for item in asset:
                if "file" in item.attrib:
                    item.attrib["file"] = item.attrib["file"].replace("./", f"{robot_dir}/")
                combined_asset.append(item)

    worldbody = ET.SubElement(mujoco_el, "worldbody")
    ET.SubElement(worldbody, "geom", type="plane", size="2 2 .1", rgba=".9 .9 .9 1")
    ET.SubElement(worldbody, "light", pos="0 0 3", dir="0 0 -1", directional="true")

    inc1 = ET.SubElement(worldbody, "include")
    inc1.set("file", f"{robot_dir}/meca_500_r1.xml")
    inc2 = ET.SubElement(worldbody, "include")
    inc2.set("file", f"{robot_dir}/meca_500_r2.xml")

    tree = ET.ElementTree(mujoco_el)
    ET.indent(tree)
    tree.write(output_xml)
    print(f"Scene written: {output_xml}")





build_scene("meca_500/meca_500.xml")