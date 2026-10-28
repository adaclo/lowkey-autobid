// Servidor sBID simulado para tests (y para probar a mano: node dev/mock-sbid.js; usuario alumne / secret).
const http = require('node:http');

const BASE_ACTS = [
  ['101', '1.3. Participació en la gestió de recursos en xarxa identificant les restriccions de seguretat.'],
  ['102', '1.4. Utilització d’aplicacions informàtiques per elaborar documentació tècnica.'],
  ['103', '1.5. Utilització d’entorns de desenvolupament per editar, depurar i provar codi.'],
  ['104', '2.4. Execució de consultes directes i procediments sobre la base de dades.'],
  ['105', '2.8. Elaboració de la documentació associada a la gestió de les bases de dades.'],
];
// MOCK_ACTS=31 genera un plan largo (como uno real) para probar la lista a mano
const N = Number(process.env.MOCK_ACTS || 0);
const ACTS = N > BASE_ACTS.length ? Array.from({ length: N }, (_, i) => [String(100 + i), `${Math.floor(i / 6) + 1}.${(i % 6) + 1}. Activitat de prova numero ${i + 1} amb una descripcio llarga per veure com es retalla el text a la pantalla de la consola`]) : BASE_ACTS;
const HOURS = [0, 0.25, 0.5, 0.75, 1, 1.25, 1.5, 1.75, 2, 2.25, 2.5, 2.75, 3, 3.25, 3.5, 3.75, 4];
const hoursOptions = HOURS.map((h) => `<option value="${h === Math.floor(h) ? h.toFixed(1) : h}">${h}</option>`).join('');
const ratingOptions = '<option value="">- Seleccionar -</option><option value="33">SENSE VALORACIÓ</option><option value="30">ADEQUADA</option><option value="29">MOLT ADEQUADA</option>';

function startMock(pending) {
  const state = { loggedIn: new Set(), saved: {}, reports: {}, pending: pending.slice(), logins: 0, rejectDaySave: false };
  const fmt = (d) => `${d.slice(6, 8)}/${d.slice(4, 6)}/${d.slice(0, 4)}`;
  const server = http.createServer((req, res) => {
    const u = new URL(req.url, 'http://x');
    const cookie = (req.headers.cookie || '').match(/JSESSIONID=(\w+)/);
    const sid = cookie && cookie[1];
    const send = (code, body, headers = {}) => {
      res.writeHead(code, { 'Content-Type': 'text/html', ...headers });
      res.end(body);
    };
    let raw = '';
    req.on('data', (c) => (raw += c));
    req.on('end', () => {
      const body = new URLSearchParams(raw);
      const authed = sid && state.loggedIn.has(sid);
      if (u.pathname === '/sBid/modules/Login' && req.method === 'GET') return send(200, '<form id="loginForm"></form>', { 'Set-Cookie': 'JSESSIONID=abc123; Path=/sBid' });
      if (u.pathname === '/sBid/modules/Login' && req.method === 'POST') {
        state.logins++;
        if (body.get('username') === 'alumne' && body.get('password') === 'secret' && body.get('moduleaction') === 'doLogin') {
          state.loggedIn.add('rot789');
          return send(302, '', { Location: '/sBid/modules/Agenda?moduleaction=show', 'Set-Cookie': 'JSESSIONID=rot789; Path=/sBid; Secure; HttpOnly' });
        }
        return send(200, '<form id="loginForm"></form>');
      }
      if (u.pathname === '/sBid/jsp/doLogout.jsp') {
        state.loggedIn.clear();
        return send(200, 'bye');
      }
      if (!authed || !req.headers.referer) return send(200, '<form id="loginForm"></form>');

      if (u.pathname === '/sBid/modules/Agenda') {
        const items = state.pending.slice(0, 3).map((p) =>
          p.report
            ? `<li><a href="/sBid/modules/ActivitatValoracioFct?moduleaction=show&amp;pk=${p.date}&amp;hash_code=h${p.date}">${fmt(p.date)}: Informe periòdic (1)</a></li>`
            : `<li><a href="/sBid/modules/ActivitatFct?moduleaction=show&amp;codi_conveni=1&amp;data=${p.date}&amp;hash_code=h${p.date}">${fmt(p.date)}: Activitat diària del dossier (1)</a></li>`
        );
        return send(200, `<div id="heading1"><span class="badge">${state.pending.length}</span></div><div id="collapse1"><ul>${items.join('')}</ul></div>`);
      }
      if (u.pathname === '/sBid/modules/ActivitatFct' && req.method === 'GET') {
        const acts = ACTS.map(([id, label]) => `<div>${label}</div><select name="inp_${id}">${hoursOptions}</select>`).join('');
        return send(200, `<form id="workingForm"><input type="hidden" name="moduleaction" value=""><input type="hidden" name="data" value="${u.searchParams.get('data')}"><input type="hidden" name="hash_code" value="${u.searchParams.get('hash_code')}"><input type="hidden" name="horesConsignades" value="0"><div>Hores màximes:<br>4H</div>${acts}</form>`);
      }
      if (u.pathname === '/sBid/modules/ActivitatFct' && req.method === 'POST') {
        const total = [...body.entries()].filter(([k]) => k.startsWith('inp_')).reduce((t, [, v]) => t + Number(v), 0);
        if (state.rejectDaySave || body.get('moduleaction') !== 'save' || total > 4 || total !== Number(body.get('horesConsignades')) || body.get('hash_code') !== 'h' + body.get('data')) return send(500, 'no');
        state.saved[body.get('data')] = Object.fromEntries([...body.entries()].filter(([k, v]) => k.startsWith('inp_') && v !== '0'));
        state.pending = state.pending.filter((p) => p.report || p.date !== body.get('data'));
        return send(200, 'ok');
      }
      if (u.pathname === '/sBid/modules/ActivitatValoracioFct' && req.method === 'GET') {
        const sel = ACTS.map(([id]) => `<select name="inp_${id}">${ratingOptions}</select>`).join('');
        return send(200, `<form id="workingForm"><input type="hidden" name="moduleaction"><input type="hidden" name="pk" value="${u.searchParams.get('pk')}">${sel}</form>`);
      }
      if (u.pathname === '/sBid/modules/ActivitatValoracioFct' && req.method === 'POST') {
        state.reports[body.get('pk')] = [...body.entries()].filter(([k]) => k.startsWith('inp_')).map(([, v]) => v);
        state.pending = state.pending.filter((p) => !(p.report && p.date === body.get('pk')));
        return send(200, 'ok');
      }
      send(404, 'nf');
    });
  });
  return new Promise((r) => server.listen(0, '127.0.0.1', () => r({ server, state, baseUrl: `http://127.0.0.1:${server.address().port}` })));
}

/*TESTS*/


module.exports = { startMock };

if (require.main === module) {
  const days = [];
  for (let d = new Date(2026, 5, 1); days.length < 25; d.setDate(d.getDate() + 1)) {
    if (d.getDay() % 6 !== 0) days.push({ date: d.toISOString().slice(0, 10).replace(/-/g, '') });
  }
  days.splice(3, 0, { date: '20260605', report: true });
  startMock(days).then((m) => {
    m.server.close();
    const port = Number(process.env.MOCK_PORT || 8765);
    m.server.listen(port, '127.0.0.1', () => console.log('mock sBID en http://127.0.0.1:' + port + '  (usuario alumne / secret)'));
  });
}
