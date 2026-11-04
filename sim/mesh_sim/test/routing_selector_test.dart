import 'dart:convert';
import 'dart:io';
import 'package:duman_mesh_sim/mesh_sim.dart';
import 'package:test/test.dart';

void main() {
  final fixture=jsonDecode(File('../../test-fixtures/routing-selector.json').readAsStringSync()) as Map;
  for(final raw in fixture['cases'] as List) {
    final row=raw as Map;
    test(row['name'] as String,() {
      final s=RoutingSelector(RoutingSelectorOptions(row['mode'] as String,row['model']));
      for(final step in row['steps'] as List) {
        final c=step['context'] as Map;
        final context=LocalRoutingContext((c['neighbors'] as num).toDouble(),(c['queue'] as num).toDouble(),
          (c['duty'] as num).toDouble(),(c['battery'] as num).toDouble(),c['saver'] as bool,(c['observedAt'] as num).toDouble());
        expect(s.decide(context,(step['now'] as num).toDouble()).toJson(),step['expected']);
      }
    });
  }
  test('nonfinite feature rejection and rollback',() {
    expect(normalizeRoutingContext(const LocalRoutingContext(double.nan,0,0,.8,false,0),0),isNull);
    final s=RoutingSelector(RoutingSelectorOptions('shadow'));
    s.rollback();expect(s.decide(const LocalRoutingContext(0,0,0,.8,false,0),0).reason,'latched-baseline');
  });
  test('shadow/canary integration preserves baseline',() {
    const model={'schema':1,'api':1,'experimental':true,'threshold':8,'left':'baseline-v1','right':'ack-6000-v1','confidence':1};
    for(final mode in ['baseline','shadow','canary']) {
      final a=MeshSimulation(campusQuad(42)), b=MeshSimulation(campusQuad(42),RoutingSelectorOptions(mode,model));
      for(var i=0;i<20;i++) {
        for(final s in [a,b]) {
          s.sendMessage(s.nodes[i%20].id,s.nodes[(i+5)%20].id,'m$i',MsgType.text);s.runFor(1500);s.refresh();
        }
      }
      expect(b.deliveries.map((d)=>[d.msgId,d.hops,d.latencyMs,d.attempt,d.dtn,d.path]).toList(),a.deliveries.map((d)=>[d.msgId,d.hops,d.latencyMs,d.attempt,d.dtn,d.path]).toList());
      expect(b.stats.toJson(),a.stats.toJson());
      expect(b.selectorDiagnostics,isNotEmpty);
      expect(b.selectorDiagnostics.every((d)=>d.applied=='baseline-v1'),isTrue);
      b.rollbackRoutingSelector();
    }
  });
  test('explicit motion stream is reproducible',() {
    final cfg=campusQuad(7),a=MeshSimulation(campusQuad(7),null,77);
    final b=MeshSimulation(cfg.copyWith(ackTimeoutMs:6000),null,77);
    for(final s in [a,b]) {s.sendMessage(s.nodes[0].id,s.nodes[10].id,'motion',MsgType.text);s.runFor(30000);}
    expect(a.nodes.map((n)=>[n.pos.x,n.pos.y]).toList(),b.nodes.map((n)=>[n.pos.x,n.pos.y]).toList());
  });
}
