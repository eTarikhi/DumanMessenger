/// Immutable offline/shadow policy interface. No network, user data, or training.
library;

class LocalRoutingContext {
  const LocalRoutingContext(this.neighbors, this.queue, this.duty, this.battery,
      this.saver, this.observedAt);
  final double neighbors, queue, duty, battery, observedAt;
  final bool saver;
}

class RoutingModel {
  const RoutingModel._(this.threshold, this.left, this.right, this.confidence);
  final double threshold, confidence;
  final String left, right;
  static RoutingModel? parse(Object? raw) {
    try {
      if (raw is! Map) return null;
      final t = raw['threshold'], c = raw['confidence'];
      const actions = ['baseline-v1', 'ack-6000-v1'];
      if (raw['schema'] != 1 || raw['api'] != 1 || raw['experimental'] != true ||
          t is! num || !t.isFinite || ![4,8,12,16,24].contains(t) ||
          c is! num || !c.isFinite || c < 0 || c > 1 ||
          !actions.contains(raw['left']) || !actions.contains(raw['right'])) return null;
      return RoutingModel._(t.toDouble(), raw['left'] as String, raw['right'] as String, c.toDouble());
    } catch (_) { return null; }
  }
}

class RoutingSelectorOptions {
  RoutingSelectorOptions(this.mode, [Object? raw]) : model = RoutingModel.parse(raw);
  final String mode;
  final RoutingModel? model;
}

class SelectorDecision {
  const SelectorDecision(this.proposed, this.applied, this.reason, this.switches);
  final String proposed, applied, reason;
  final int switches;
  Map<String, Object> toJson() => {'proposed':proposed,'applied':applied,'reason':reason,'switches':switches};
}

List<double>? normalizeRoutingContext(LocalRoutingContext c, double now) {
  if (![now,c.observedAt,c.neighbors,c.queue,c.duty,c.battery].every((x)=>x.isFinite) ||
      c.observedAt>now || now-c.observedAt>10000 || c.neighbors<0 || c.neighbors>128 ||
      c.queue<0 || c.queue>500 || c.neighbors!=c.neighbors.floorToDouble() ||
      c.queue!=c.queue.floorToDouble() || ![0,1].contains(c.duty) || c.battery<0 || c.battery>1) return null;
  return [c.neighbors/128,c.duty,c.queue/500];
}

class RoutingSelector {
  RoutingSelector(this.options);
  final RoutingSelectorOptions options;
  String _current='baseline-v1', _pending='baseline-v1';
  int _votes=0, _changes=0;
  double _lastSwitch=double.negativeInfinity, _lastNow=double.negativeInfinity,
      _lastVoteAt=double.negativeInfinity;
  bool _latched=false;
  void rollback() { _latched=true; _current='baseline-v1'; }
  SelectorDecision _answer(String reason)=>SelectorDecision(_current,'baseline-v1',reason,_changes);
  SelectorDecision decide(LocalRoutingContext c, double now) {
    try { return _evaluate(c,now); }
    catch (_) { rollback(); return _answer('inference-error'); }
  }
  SelectorDecision _evaluate(LocalRoutingContext c, double now) {
    if(options.mode=='baseline') return _answer('baseline-mode');
    if(_latched) return _answer('latched-baseline');
    final model=options.model;
    if(!['shadow','canary'].contains(options.mode)||model==null) {rollback();return _answer('invalid-model');}
    final normalized=normalizeRoutingContext(c,now);
    if(normalized==null||now<_lastNow) {rollback();return _answer('invalid-context');}
    _lastNow=now;
    if(c.saver||c.battery<.25||c.duty==1) {_current='baseline-v1';_votes=0;_pending='baseline-v1';return _answer('power-override');}
    if(model.confidence<.6) return _answer('low-confidence');
    final proposal=normalized[0]<=model.threshold/128?model.left:model.right;
    if(c.observedAt>_lastVoteAt) {
      if(proposal!=_pending) {_pending=proposal;_votes=1;} else {_votes++;}
      _lastVoteAt=c.observedAt;
    }
    if(proposal!=_current&&_votes>=3&&now-_lastSwitch>=30000&&_changes<4) {
      _current=proposal;_lastSwitch=now;_changes++;
    }
    return _answer(options.mode=='canary'?'approval-required':'shadow-only');
  }
}
