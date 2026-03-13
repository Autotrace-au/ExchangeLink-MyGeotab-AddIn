#!/usr/bin/env python3
"""Update MyGeotab device custom properties.
Reads properties JSON from stdin and outputs a single JSON result line at end.
All diagnostics are printed earlier (stdout for payload-level info, stderr for environment details).
"""
import sys, json, traceback
import mygeotab

PROP_NAME_MAP = {
    'bookable': 'Enable Equipment Booking',
    'recurring': 'Allow Recurring Bookings',
    'approvers': 'Booking Approvers',
    'fleetManagers': 'Fleet Managers',
    'conflicts': 'Allow Double Booking',
    'windowDays': 'Booking Window (Days)',
    'maxDurationHours': 'Maximum Booking Duration (Hours)',
    'language': 'Mailbox Language'
}

def log_env(api):
    print(f'DEBUG: Python version: {sys.version}', file=sys.stderr)
    print(f'DEBUG: mygeotab version: {mygeotab.__version__}', file=sys.stderr)


def fetch_device(api, device_id_or_identifier):
    """Fetch a device by id; if not found, fallback to serialNumber then name.
    Allows callers to supply serial or name transparently instead of internal id.
    """
    # Try direct id lookup
    devices = api.get('Device', search={'id': device_id_or_identifier}) or []
    if devices:
        print(f'DEBUG: Device resolved by id={device_id_or_identifier}')
        return devices[0]
    # Fallback: serialNumber
    devices = api.get('Device', search={'serialNumber': device_id_or_identifier}) or []
    if devices:
        print(f'DEBUG: Device resolved by serialNumber={device_id_or_identifier}')
        return devices[0]
    # Fallback: name
    devices = api.get('Device', search={'name': device_id_or_identifier}) or []
    if devices:
        print(f'DEBUG: Device resolved by name={device_id_or_identifier}')
        return devices[0]
    raise RuntimeError(f'Device not found by id/serial/name: {device_id_or_identifier}')


def dump_original(device):
    orig_cp = device.get('customProperties', []) or []
    print('DEBUG: ORIGINAL customProperties COUNT=' + str(len(orig_cp)))
    from json import dumps as _d
    for i, pv in enumerate(orig_cp[:15]):
        print(f'DEBUG: ORIGINAL CP[{i}] keys={list(pv.keys())} value={pv.get("value")} data={pv.get("data")}')
        try:
            print(_d(pv, indent=2)[:1000])
        except Exception:
            pass


def build_property_lookup(api):
    all_props = api.get('Property')
    lookup = {}
    for key, name in PROP_NAME_MAP.items():
        mp = next((p for p in all_props if p.get('name') == name), None)
        if mp:
            lookup[key] = {
                'id': mp['id'],
                'setId': mp.get('propertySet', {}).get('id'),
                'name': name,
            }
            try:
                short = {k: mp.get(k) for k in ['id','name','dataType','type','valueType'] if k in mp}
                print('DEBUG: PropertyDefinition ' + key + ' ' + json.dumps(short))
            except Exception:
                pass
        else:
            print(f'WARN: Property definition not found for {key} ({name})', file=sys.stderr)
    print(f'DEBUG: Found {len(lookup)} property definitions')
    return lookup


def normalize_existing(pv):
    # Migrate legacy 'data' field if present
    if 'data' in pv and 'value' not in pv:
        pv['value'] = pv.pop('data')
    if 'data' in pv:  # if both present after above, drop data
        del pv['data']


def apply_value(existing_pv, new_val):
    normalize_existing(existing_pv)
    existing_pv['value'] = new_val


def update_properties(device, properties, lookup):
    original_cp = device.get('customProperties', []) or []
    # Normalize existing (migrate data->value, drop data)
    for pv in original_cp:
        normalize_existing(pv)

    def to_string(v):
        if v is None:
            return ''  # server seems to store blanks as empty string
        if isinstance(v, bool):
            return 'true' if v else 'false'
        return str(v)

    # Build two parallel lists: typed (attempt 2) and coerced string (attempt 1)
    typed_list = []
    string_list = []

    # Index existing property values by property id for reuse of id/version where present
    existing_by_prop = {}
    for pv in original_cp:
        prop_id = pv.get('property', {}).get('id')
        if prop_id:
            existing_by_prop[prop_id] = pv

    for key, incoming_val in properties.items():
        if key not in lookup:
            print(f'Property not found: {key}', file=sys.stderr)
            continue
        info = lookup[key]
        raw_val = incoming_val if incoming_val != '' else None
        print(f'SET: {key} id={info["id"]} value={raw_val} type={type(raw_val).__name__}')
        existing_pv = existing_by_prop.get(info['id'])

        # Build typed variant (mirrors original structure + new value)
        if existing_pv:
            typed_obj = {
                k: v for k, v in existing_pv.items() if k in ('id', 'version')  # preserve identity/version if present
            }
            typed_obj['property'] = {'id': info['id'], 'propertySet': {'id': info['setId']}}
            typed_obj['value'] = raw_val
            # Only include 'value' field even if previous stored as string/blank
        else:
            typed_obj = {
                'property': {'id': info['id'], 'propertySet': {'id': info['setId']}},
                'value': raw_val
            }
        typed_list.append(typed_obj)

        # Build string-coerced variant
        string_val = to_string(raw_val)
        if existing_pv:
            str_obj = {
                k: v for k, v in existing_pv.items() if k in ('id', 'version')
            }
            str_obj['property'] = {'id': info['id'], 'propertySet': {'id': info['setId']}}
            str_obj['value'] = string_val
        else:
            str_obj = {
                'property': {'id': info['id'], 'propertySet': {'id': info['setId']}},
                'value': string_val
            }
        string_list.append(str_obj)
        print(f'DEBUG BUILD {key}: typedValue={raw_val} stringValue={string_val}')

    return typed_list, string_list, original_cp


def dump_payload(custom_properties):
    print('PAYLOAD COUNT=' + str(len(custom_properties)))
    from json import dumps as _d2
    for i, pv in enumerate(custom_properties[:15]):
        print(f'PAYLOAD[{i}] keys={list(pv.keys())} value={pv.get("value")}')
        try:
            print(_d2(pv, indent=2)[:800])
        except Exception:
            pass


def post_fetch(api, device_id):
    post = api.get('Device', search={'id': device_id})
    if not post:
        print('POST-FETCH: device missing')
        return
    cp = post[0].get('customProperties', []) or []
    from json import dumps as _d3
    print('POST-FETCH COUNT=' + str(len(cp)))
    for i, pv in enumerate(cp[:20]):
        print(f'POST[{i}] keys={list(pv.keys())} value={pv.get("value")} data={pv.get("data")}')
        try:
            print(_d3(pv, indent=2)[:800])
        except Exception:
            pass


def main():
    try:
        if len(sys.argv) < 5:
            raise SystemExit('Missing args: --username --password --database --device-id')
        # Simple arg parsing
        args = sys.argv[1:]
        arg_map = {}
        key = None
        for a in args:
            if a.startswith('--'):
                key = a[2:]
                arg_map[key] = ''
            else:
                if key is None:
                    raise SystemExit('Invalid arg ordering')
                arg_map[key] = a
        username = arg_map.get('username')
        password = arg_map.get('password')
        database = arg_map.get('database')
        device_id = arg_map.get('device-id')
        props_json = sys.stdin.read()
        properties = json.loads(props_json) if props_json.strip() else {}

        api = mygeotab.API(username=username, password=password, database=database)
        api.authenticate()
        log_env(api)
        device = fetch_device(api, device_id)
        print(f'DEBUG: Device retrieved name={device.get("name")} id={device.get("id")}', file=sys.stderr)
        dump_original(device)
        lookup = build_property_lookup(api)
        typed_cp, string_cp, original_cp = update_properties(device, properties, lookup)
        print('ATTEMPT 1: minimal string-coerced payload')
        dump_payload(string_cp)
        # Attempt minimal string payload first
        error = None
        try:
            api.set('Device', {'id': device['id'], 'customProperties': string_cp})
            print('SET SUCCESS minimal string payload')
        except Exception as e1:
            error = e1
            print(f'SET FAIL minimal string payload: {e1}')

        # Attempt minimal typed payload if first failed
        if error:
            print('ATTEMPT 2: minimal typed payload')
            dump_payload(typed_cp)
            try:
                api.set('Device', {'id': device['id'], 'customProperties': typed_cp})
                print('SET SUCCESS minimal typed payload')
                error = None
            except Exception as e2:
                error = e2
                print(f'SET FAIL minimal typed payload: {e2}')

        # Attempt full payload with string-coerced values if still failing
        if error:
            print('ATTEMPT 3: full device + string-coerced customProperties')
            full_update = {k: v for k, v in device.items() if k in ('id','name')}  # reduce size but include id/name
            full_update['customProperties'] = string_cp
            import requests, json as _json_ins
            _orig_post = requests.Session.post
            def _patched_post(self, url, *args, **kwargs):
                try:
                    payload = kwargs.get('json') or kwargs.get('data')
                    print('DEBUG RAW REQUEST BEGIN')
                    if isinstance(payload, (dict, list)):
                        print(_json_ins.dumps(payload, indent=2)[:4000])
                    elif isinstance(payload, str):
                        print(payload[:4000])
                    print('DEBUG RAW REQUEST END')
                except Exception as _ie:
                    print(f'DEBUG RAW REQUEST ERROR: {_ie}')
                return _orig_post(self, url, *args, **kwargs)
            requests.Session.post = _patched_post
            try:
                api.set('Device', full_update)
                print('SET SUCCESS full string payload')
                error = None
            except Exception as e3:
                error = e3
                print(f'SET FAIL full string payload: {e3}')
            finally:
                requests.Session.post = _orig_post

        # Final post-fetch to inspect persisted state
        post_fetch(api, device_id)
        success = error is None
        print(json.dumps({'success': success, 'message': 'Update ' + ('succeeded' if success else 'failed'), 'deviceId': device_id, 'database': database, 'attempts': 3, 'error': str(error) if error else None}))
    except Exception as e:
        print('ERROR: ' + str(e), file=sys.stderr)
        traceback.print_exc(file=sys.stderr)
        print(json.dumps({'success': False, 'error': str(e)}))
        sys.exit(1)

if __name__ == '__main__':
    main()
