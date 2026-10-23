// Makes the made-up Loro documents in this folder, and beside each the JSON Loro itself
// reads out of it, for LoroKit's and Workspaces' tests to hold this app's reading
// against. Everything in them is made up.
//
// Run by hand, never by a build or a test (the tests read only what it wrote):
//
//     mkdir /tmp/loro && cd /tmp/loro && npm install loro-crdt@1.16.3
//     cp <this folder>/make-fixtures.mjs /tmp/loro/ && node /tmp/loro/make-fixtures.mjs <this folder>
//
// (It is copied beside the package because Node looks for a module beside the script.)
//
// (loro-crdt is Loro's own JavaScript package: the reader this app's is checked against.
// It is not a dependency of the app; nothing here is built into it.)
//
// The documents:
//
//   containers   every kind of container, edited by two people at once, with things
//                deleted, moved and set again, a mergeable child, and enough in it to be
//                kept in several blocks, compressed, and one value too large for a block
//   presentation a made-up presentation, shaped as ProPresenter 22 keeps one: a map of
//                its parts named as the message's fields, its slides kept by id, its
//                groups a tree, an arrangement's groups in "group_identifiers_v2"
//   playlists    a made-up PlaylistLibrary: the playlists a mergeable tree
//   libraries    a made-up LibraryData: the list of libraries
//
// Each .json is Loro's toJSON(), with binary data written as "base64:" and its Base64.

import { LoroDoc, LoroMap, LoroMovableList, LoroList, LoroText, LoroTree, LoroCounter } from 'loro-crdt';
import fs from 'fs';
import path from 'path';

const out = process.argv[2];
if (!out) throw new Error('say where to write');

function save(name, doc) {
    const bytes = doc.export({ mode: 'snapshot' });
    fs.writeFileSync(path.join(out, name + '.loro'), bytes);
    const fix = v => {
        if (v instanceof Uint8Array) return 'base64:' + Buffer.from(v).toString('base64');
        if (Array.isArray(v)) return v.map(fix);
        if (v && typeof v === 'object') { const o = {}; for (const [k, x] of Object.entries(v)) o[k] = fix(x); return o; }
        return v;
    };
    fs.writeFileSync(path.join(out, name + '.json'), JSON.stringify(fix(doc.toJSON()), null, 1) + '\n');
    console.log(name, bytes.length, 'bytes');
}

/// Writes a plain JavaScript value into a map as ProPresenter does: an object as a map
/// container, an array as a movable list, anything else as a value.
function put(map, key, value) {
    if (Array.isArray(value)) {
        const list = map.setContainer(key, new LoroMovableList());
        value.forEach((v, i) => pushInto(list, i, v));
    } else if (value && typeof value === 'object' && !(value instanceof Uint8Array)) {
        const child = map.setContainer(key, new LoroMap());
        for (const [k, v] of Object.entries(value)) put(child, k, v);
    } else {
        map.set(key, value);
    }
}

function pushInto(list, index, value) {
    if (Array.isArray(value)) {
        const inner = list.insertContainer(index, new LoroMovableList());
        value.forEach((v, i) => pushInto(inner, i, v));
    } else if (value && typeof value === 'object' && !(value instanceof Uint8Array)) {
        const child = list.insertContainer(index, new LoroMap());
        for (const [k, v] of Object.entries(value)) put(child, k, v);
    } else {
        list.insert(index, value);
    }
}

// ---- containers

{
    const a = new LoroDoc();
    a.setPeerId(1);
    const root = a.getMap('root');
    root.set('text', 'Made up');
    root.set('number', 3.25);
    root.set('whole', 42);
    root.set('negative', -7);
    root.set('yes', true);
    root.set('nothing', null);
    root.set('bytes', new Uint8Array([0, 1, 2, 250, 255]));
    root.set('plain', { inner: [1, 'two', { three: 3 }] });
    root.set('ünïcödé ✓', 'keys too');
    root.set('gone', 'deleted below');
    const list = root.setContainer('list', new LoroList());
    for (let i = 0; i < 6; i++) list.insert(i, 'item ' + i);
    list.delete(1, 2);
    const movable = root.setContainer('movable', new LoroMovableList());
    for (let i = 0; i < 5; i++) movable.insert(i, i * 10);
    movable.move(0, 4);
    movable.set(2, 'set again');
    movable.delete(1, 1);
    const nested = movable.insertContainer(0, new LoroMap());
    nested.set('in a list', true);
    const text = root.setContainer('text container', new LoroText());
    text.insert(0, 'Hello made-up world');
    text.delete(6, 8);
    text.mark({ start: 0, end: 5 }, 'bold', true);
    const counter = root.setContainer('counter', new LoroCounter());
    counter.increment(5);
    counter.decrement(1.5);
    const tree = root.setContainer('tree', new LoroTree());
    const top = tree.createNode();
    top.data.set('name', 'top');
    const kids = [];
    for (let i = 0; i < 4; i++) {
        const kid = top.createNode();
        kid.data.set('name', 'child ' + i);
        kids.push(kid);
    }
    kids[3].move(top, 0);
    tree.delete(kids[1].id);
    const second = tree.createNode();
    second.data.set('name', 'second top');
    kids[2].move(second);
    tree.createNode(); // a node whose data is never written
    root.ensureMergeableTree('mergeable tree').createNode().data.set('name', 'in a mergeable tree');
    root.ensureMergeableMap('mergeable map').set('kept', 'in a mergeable map');
    root.delete('gone');
    // Large enough to be kept in blocks of their own, and compressed.
    root.set('large', 'made-up words, over and over. '.repeat(400));
    const many = root.setContainer('many', new LoroMap());
    for (let i = 0; i < 300; i++) {
        const m = many.setContainer('entry ' + String(i).padStart(3, '0'), new LoroMap());
        m.set('value', i);
        m.set('words', 'entry number ' + i);
    }
    a.commit();

    // A second person, at the same time.
    const b = new LoroDoc();
    b.setPeerId(2);
    b.import(a.export({ mode: 'snapshot' }));
    const rootB = b.getMap('root');
    rootB.set('text', 'Made up, by the second');
    rootB.get('movable').insert(0, 'from the second');
    rootB.get('tree').createNode().data.set('name', 'from the second');
    a.getMap('root').get('list').insert(0, 'from the first, at once');
    a.commit();
    b.commit();
    a.import(b.export({ mode: 'update' }));
    save('containers', a);
}

// ---- a presentation

const RTF = s => new TextEncoder().encode(
    '{\\rtf1\\ansi\\ansicpg1252\\cocoartf2822\n{\\fonttbl\\f0\\fswiss\\fcharset0 Helvetica;}\n' +
    '{\\colortbl;\\red255\\green255\\blue255;}\n{\\*\\expandedcolortbl;;\\csgenericrgb\\c100000\\c100000\\c100000;}\n' +
    '\\pard\\qc\\partightenfactor0\n\n\\f0\\fs160 \\cf2 ' + s + '}');

const id = n => '00000000-0000-4000-8000-' + String(n).padStart(12, '0');
const white = { red: 1, green: 1, blue: 1, alpha: 1 };

function textSlide(words, n) {
    return {
        uuid: id(100 + n), name: '', isEnabled: true, delay_time: 0, type: 11,
        label: null,
        ActionTypeData: {
            __tag: 'slide',
            slide: {
                Slide: {
                    __tag: 'presentation',
                    presentation: {
                        notes: null,
                        template_guidelines: [],
                        base_slide: {
                            uuid: id(200 + n),
                            size: { width: 1920, height: 1080 },
                            draws_background_color: false,
                            background_color: null,
                            element_build_order_v2: [],
                            guidelines: [],
                            elements: [{
                                reveal_from_index: 0,
                                childBuilds: [],
                                data_links: [],
                                element: {
                                    uuid: id(300 + n), name: 'Words', opacity: 1, locked: false, aspect_ratio_locked: false,
                                    bounds: { origin: { x: 160, y: 140 }, size: { width: 1600, height: 800 } },
                                    fill: { enable: false, FillType: { __tag: 'color', color: white } },
                                    stroke: { enable: false, width: 3, style: 0, color: white },
                                    Mask: { __tag: null },
                                    text: {
                                        rtf_data: RTF(words),
                                        vertical_alignment: 1,
                                        scale_behavior: 0,
                                        transform: 0,
                                        transformDelimiter: '',
                                        margins: { top: 0, left: 0, bottom: 0, right: 0 },
                                        alternate_texts: [],
                                        attributes: { font: { name: 'Helvetica', family: 'Helvetica', size: 80, bold: false, italic: false }, custom_attributes: [] },
                                    },
                                },
                            }],
                        },
                    },
                },
            },
        },
    };
}

function backgroundPicture(n) {
    return {
        uuid: id(400 + n), name: '', isEnabled: true, delay_time: 0, type: 2,
        ActionTypeData: {
            __tag: 'media',
            media: {
                layer_type: 0,
                markers: [],
                MediaType: { __tag: 'image', image: {} },
                element: {
                    uuid: id(500 + n),
                    asset_id: id(600 + n),
                    identity_schema_version: '1',
                    metadata: { format: 'png' },
                    TypeProperties: {
                        __tag: 'image',
                        image: {
                            source: { SourceType: { __tag: null } },
                            drawing: { natural_size: { width: 1920, height: 1080 }, scale_behavior: 1, effects: [] },
                            file: {
                                local_url: {
                                    platform: 1,
                                    RelativeFilePath: { __tag: 'local', local: { root: 10, path: 'Media/Assets/Made Up Background.png' } },
                                    Storage: { __tag: 'absolute_string', absolute_string: 'file:///Users/someone/Made%20Up/Media/Assets/Made%20Up%20Background.png' },
                                },
                                remote_properties: { procontent: { download_identifier: null } },
                            },
                        },
                    },
                },
            },
        },
    };
}

function cue(n, name, actions) {
    return { uuid: id(n), name, isEnabled: true, completion_target_type: 0, completion_action_type: 0, completion_time: 0, actions };
}

{
    const doc = new LoroDoc();
    doc.setPeerId(7);
    const root = doc.getMap('root');
    const cues = {
        [id(1)]: cue(1, 'Verse one, first', [textSlide('Made-up words, verse one', 1), backgroundPicture(1)]),
        [id(2)]: cue(2, 'Verse one, second', [textSlide('More made-up words', 2)]),
        [id(3)]: cue(3, 'Chorus', [textSlide('A made-up chorus', 3)]),
        [id(4)]: cue(4, 'In no group', [textSlide('Never shown', 4)]),
    };
    const parts = {
        uuid: id(9000), name: 'Made-Up Song', notes: '', value_array_migration_version: '1',
        selected_arrangement: null,
        SlideShow: { __tag: null },
        background: { is_enabled: false, Fill: { __tag: null } },
        ccli: { display: false, song_title: null, author: null },
        timeline: { duration: 300, loop: false, cues_v2: [] },
        arrangements: [
            { uuid: id(9100), name: 'Chorus first', group_identifiers_v2: [id(8002), id(8001), id(8002)] },
        ],
        cues,
    };
    for (const [k, v] of Object.entries(parts)) put(root, k, v);
    const placements = root.setContainer('cue_group_placements', new LoroTree());
    const groups = [
        { gid: id(8001), name: 'Verse 1', cues: [id(1), id(2)], color: { red: 0, green: 0.5, blue: 1, alpha: 1 } },
        { gid: id(8002), name: 'Chorus', cues: [id(3)], color: { red: 1, green: 0, blue: 0, alpha: 1 } },
    ];
    for (const g of groups) {
        const node = placements.createNode();
        put(node.data, 'uuid', g.gid);
        put(node.data, 'Kind', { __tag: 'group', group: { name: g.name, color: g.color, hot_key: { code: 0 }, application_group_identifier: null } });
        for (const c of g.cues) {
            const child = node.createNode();
            put(child.data, 'uuid', c);
            put(child.data, 'Kind', { __tag: 'cue', cue: {} });
        }
    }
    doc.commit();
    save('presentation', doc);
}

// ---- the playlists

{
    const doc = new LoroDoc();
    doc.setPeerId(8);
    const root = doc.getMap('root');
    const tree = root.ensureMergeableTree('playlists');
    const top = tree.createNode();
    put(top.data, 'uuid', id(7000));
    put(top.data, 'name', 'PLAYLIST');
    put(top.data, 'Kind', { __tag: 'group', group: {} });
    const folder = top.createNode();
    put(folder.data, 'uuid', id(7001));
    put(folder.data, 'name', 'Made-Up Folder');
    put(folder.data, 'Kind', { __tag: 'group', group: {} });
    const playlist = folder.createNode();
    put(playlist.data, 'uuid', id(7002));
    put(playlist.data, 'name', 'Made-Up Sunday');
    put(playlist.data, 'Kind', { __tag: 'playlist', playlist: { LinkData: { __tag: null } } });
    const items = [
        { uuid: id(7101), name: 'Before', ItemType: { __tag: 'header', header: { color: white, actions: [] } } },
        { uuid: id(7102), name: 'Made-Up Song', ItemType: { __tag: 'presentation', presentation: {
            document_path: { platform: 1, RelativeFilePath: { __tag: 'local', local: { root: 10, path: 'Libraries/Made Up/Made-Up Song.pro' } }, Storage: null },
            arrangement: id(9100), arrangement_name: 'Chorus first', content_destination: 0 } } },
        { uuid: id(7103), name: 'A made-up video', ItemType: { __tag: 'cue', cue: { uuid: id(7104), actions: [] } } },
        { uuid: id(7105), name: 'Not there', ItemType: { __tag: 'presentation', presentation: {
            document_path: { platform: 1, RelativeFilePath: { __tag: 'local', local: { root: 10, path: 'Libraries/Made Up/Not There.pro' } }, Storage: null },
            arrangement: null, arrangement_name: '', content_destination: 0 } } },
    ];
    for (const item of items) {
        const node = playlist.createNode();
        put(node.data, 'uuid', item.uuid);
        put(node.data, 'name', item.name);
        put(node.data, 'Kind', { __tag: 'item', item: { is_hidden: false, ItemType: item.ItemType } });
    }
    const empty = top.createNode();
    put(empty.data, 'uuid', id(7003));
    put(empty.data, 'name', 'An Empty Playlist');
    put(empty.data, 'Kind', { __tag: 'playlist', playlist: { LinkData: { __tag: null } } });
    doc.commit();
    save('playlists', doc);
}

// ---- the libraries

{
    const doc = new LoroDoc();
    doc.setPeerId(9);
    const root = doc.getMap('root');
    const url = p => ({ platform: 1, RelativeFilePath: { __tag: 'local', local: { root: 10, path: p } }, Storage: null });
    put(root, 'rootLibrary', {
        url: url('Libraries'),
        ChildType: { __tag: 'libraryChildren', libraryChildren: { libraries: [
            { url: url('Libraries/Made Up'), ChildType: { __tag: 'libraryItems', libraryItems: { items: [{ url: url('Libraries/Made Up/Made-Up Song.pro') }] } } },
            { url: url('Libraries/Empty Library'), ChildType: { __tag: 'libraryItems', libraryItems: { items: [] } } },
        ] } },
    });
    doc.commit();
    save('libraries', doc);
}
