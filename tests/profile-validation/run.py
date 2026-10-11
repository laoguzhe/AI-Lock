"""Exercise packaging preflight with synthetic profiles; no signing or deployment."""
import copy
import datetime
import pathlib
import plistlib
import subprocess
import sys
import tempfile

project = pathlib.Path(__file__).resolve().parents[2]
script = (project / 'extensions/package-extension.sh').read_text()
preflight = script.split('<<\'PY\'\n', 1)[1].split('\nPY\n', 1)[0]
team = 'ABCDE12345'
group = team + '.com.laogu.ailock.filterprototype'


def profile(identifier, host=False, audit=False):
    ent = {'com.apple.developer.team-identifier': team, 'com.apple.application-identifier': team + '.' + identifier}
    if host:
        ent['com.apple.developer.system-extension.install'] = True
    if audit:
        ent['com.apple.developer.endpoint-security.client'] = True
    else:
        ent['com.apple.developer.networking.networkextension'] = ['content-filter-provider-systemextension']
        ent['com.apple.security.application-groups'] = [group]
    return {'TeamIdentifier': [team], 'ExpirationDate': datetime.datetime.now() + datetime.timedelta(days=1), 'Entitlements': ent}


def check(name, host, extension, mode='filter', embedded=False, succeeds=False):
    with tempfile.TemporaryDirectory(prefix='ailock-profile-fixture-') as temporary:
        root = pathlib.Path(temporary)
        for label, value in [('host', host), ('filter', extension)]:
            (root / (label + '.plist')).write_bytes(plistlib.dumps(value))
        app = root / 'Fixture.app'
        if embedded:
            (app / 'Contents/Library/SystemExtensions/FilterPrototype.systemextension').mkdir(parents=True)
        result = subprocess.run([sys.executable, '-c', preflight, str(root), mode, str(app)], capture_output=True, text=True)
        assert (result.returncode == 0) == succeeds, name + ': ' + result.stderr
        if succeeds:
            selected = plistlib.loads((root / 'host.entitlements').read_bytes())
            assert selected['com.apple.security.application-groups'] == [group]
        print('PASS:', name)


host = profile('com.laogu.ailock', host=True)
filter_ext = profile('com.laogu.ailock.filterprototype')
check('matching filter profiles retain the IPC application group', host, filter_ext, succeeds=True)
missing = copy.deepcopy(host)
missing['Entitlements'].pop('com.apple.security.application-groups')
check('host profile without the IPC group is rejected', missing, filter_ext)
missing = copy.deepcopy(filter_ext)
missing['Entitlements'].pop('com.apple.security.application-groups')
check('filter profile without the IPC group is rejected', host, missing)
expired = copy.deepcopy(host)
expired['ExpirationDate'] = datetime.datetime.now() - datetime.timedelta(days=1)
check('expired profile is rejected', expired, filter_ext)
wrong = copy.deepcopy(filter_ext)
wrong['Entitlements']['com.apple.application-identifier'] = team + '.com.other.extension'
check('a profile for another extension is rejected', host, wrong)
audit = profile('com.laogu.ailock.auditprototype', audit=True)
check('audit packaging preserves the existing host NE capability without requiring it on ES', host, audit, mode='audit', embedded=True, succeeds=True)
missing = copy.deepcopy(audit)
missing['Entitlements'].pop('com.apple.developer.endpoint-security.client')
check('unapproved ES profile is rejected', host, missing, mode='audit', embedded=True)
