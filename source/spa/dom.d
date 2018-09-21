module spa.dom;

import spa.types;
import spa.dom;
import std.array : Appender;
import spa.ct;
import std.traits : hasMember;
import spa.css;
import spa.node;
import spa.event;
import std.meta : staticIndexOf;
import spa.array;

private extern(C) {
  JsHandle createElement(NodeType type);
  void addClass(JsHandle node, string className);
  void setProperty(JsHandle node, string prop, string value);
  void removeChild(JsHandle childPtr);
  void unmount(JsHandle childPtr);
  void appendChild(JsHandle parentPtr, JsHandle childPtr);
  void insertBefore(JsHandle parentPtr, JsHandle childPtr, JsHandle sibling);
  void setAttribute(JsHandle nodePtr, string attr, string value);
  void setPropertyBool(JsHandle nodePtr, string attr, bool value);
  void innerText(JsHandle nodePtr, string text);
  void addCss(string css);
  void removeClass(JsHandle node, string className);
  void changeClass(JsHandle node, string className, bool on);
}

extern(C) {
  string getProperty(JsHandle node, string prop);
  bool getPropertyBool(JsHandle node, string prop);
  void focus(JsHandle node);
  void setSelectionRange(JsHandle node, uint start, uint end);
}

void unmount(T)(auto ref T t) if (hasMember!(T, "node")) {
  unmount(t.node.node);
  t.node.mounted = false;
 }

auto removeChild(T)(auto ref T t) if (hasMember!(T,"node")) {
  removeChild(t.node.node);
  t.node.mounted = false;
 }

auto focus(T)(auto ref T t) if (hasMember!(T,"node")) {
  t.node.node.focus();
 }

auto renderBefore(T, Ts...)(JsHandle parent, auto ref T t, JsHandle sibling, auto ref Ts ts) {
  if (parent == JsHandle.max)
    return;
  renderIntoNode(parent, t, ts);
  static if (hasMember!(T, "node")) {
    parent.insertBefore(t.node.node, sibling);
    t.node.mounted = true;
  }
}

auto render(T, Ts...)(JsHandle parent, auto ref T t, auto ref Ts ts) {
  if (parent == JsHandle.max)
    return;
  renderIntoNode(parent, t, ts);
  static if (hasMember!(T, "node")) {
    parent.appendChild(t.node.node);
    t.node.mounted = true;
  }
}

auto remount(string field, Parent)(auto ref Parent parent) {
  import std.traits : FieldNameTuple, hasUDA;
  alias fields = FieldNameTuple!Parent;
  alias idx = staticIndexOf!(field,fields);
  static if (fields.length > idx+1) {
    static foreach(child; fields[idx+1..$]) {
      static if (hasUDA!(__traits(getMember, Parent, child), spa.types.child)) {
        if (__traits(getMember, parent, child).node.mounted)
          return renderBefore(parent.node.node, __traits(getMember, parent, field), __traits(getMember, parent, child).node.node, parent);
      }
    }
  }
  return render(parent.node.node, __traits(getMember, parent, field), parent);
}

auto setPointers(T, Ts...)(auto ref T t, auto ref Ts ts) {
  import std.typecons : AliasSeq;
  import std.traits : hasUDA;
  static foreach(i; __traits(allMembers, T)) {{
      alias sym = AliasSeq!(__traits(getMember, t, i))[0];
      static if (is(typeof(sym) == Prop*, Prop)) {
        setPointerFromParent!(i)(t, ts);
      }
      static if (hasUDA!(sym, child)) {
        static if (is(typeof(sym) : Appender!(Item[]), Item)) {
          // items in appenders need to be set via render functions
        } else {
          setPointers(__traits(getMember, t, i), AliasSeq!(t, ts));
        }
      }
    }}
}

auto isChildVisible(string child, Parent)(auto ref Parent parent) {
  import std.traits : ParameterIdentifierTuple;
  import std.traits : getSymbolsByUDA, getUDAs;
  alias visiblePreds = getSymbolsByUDA!(Parent, visible);
  static foreach(sym; visiblePreds) {{
      alias vs = getUDAs!(sym, visible);
      // TODO: static assert sym is callable
      static foreach(v; vs) {{
        static if (is(v == visible!name, string name) && child == name) {
          alias params = ParameterIdentifierTuple!sym;
          auto args = getMemberTuple!(Parent,params)(parent);
          if (__traits(getMember, parent, __traits(identifier, sym))(args.expand) == false)
            return false;
        }
        }}
    }}
  return true;
}

auto renderIntoNode(T, Ts...)(JsHandle parent, auto ref T t, auto ref Ts ts) {
  import std.traits : hasUDA, getUDAs, ParameterIdentifierTuple;
  import std.typecons : AliasSeq;
  import std.meta : staticMap;
  import std.traits : isCallable, getSymbolsByUDA, isPointer;
  import std.conv : text;
  enum hasNode = hasMember!(T, "node");
  static if (hasNode)
    bool shouldRender = t.node.node == JsHandle.max;
  else
    bool shouldRender = true;
  if (shouldRender) {
    auto node = createNode(parent, t);
    alias StyleSet = getStyleSet!T;
    static foreach(i; __traits(allMembers, T)) {{
        alias name = domName!i;
        alias sym = AliasSeq!(__traits(getMember, t, i))[0];
        alias styles = getStyles!(sym);
        static if (is(typeof(sym) == Prop*, Prop)) {
          if (__traits(getMember, t, i) is null)
            setPointerFromParent!(i)(t, ts);
        }
        static if (hasUDA!(sym, child)) {
          if (isChildVisible!(i)(t)) {
            static if (is(typeof(sym) : Appender!(Item[]), Item)) {
              foreach(ref item; __traits(getMember, t, i).data) {
                // TODO: we only need to pass t to a child render function when there is a child that has an alias to one of its member
                node.render(item, AliasSeq!(t, ts));
                static if (is(typeof(t) == Array!Item))
                  t.assignEventListeners(item);
              }
            } else {
              // TODO: we only need to pass t to a child render function when there is a child that has an alias to one of its member
              node.render(__traits(getMember, t, i), AliasSeq!(t, ts));
            }
          }
        } else static if (hasUDA!(sym, prop)) {
          static if (isCallable!(sym)) {
            alias params = ParameterIdentifierTuple!sym;
            auto args = getMemberTuple!(T,params)(t);
            node.setPropertyTyped!name(__traits(getMember, t, i)(args.expand));
          } else {
            node.setPropertyTyped!name(__traits(getMember, t, i));
          }
        } else static if (hasUDA!(sym, callback)) {
          node.addEventListenerTyped!i(t);
        } else static if (hasUDA!(sym, attr)) {
          static if (isCallable!(sym)) {
            alias params = ParameterIdentifierTuple!sym;
            auto args = getMemberTuple!(T,params)(t);
            node.setAttributeTyped!name(__traits(getMember, t, i)(args.expand));
          } else {
            node.setAttributeTyped!name(__traits(getMember, t, i));
          }
        } else static if (hasUDA!(sym, connect)) {
          alias connects = getUDAs!(sym, connect);
          static foreach(c; connects) {
            auto del = &__traits(getMember, t, i);
            static if (is(c: connect!(a,b), alias a, alias b)) {
              import std.array : replace;
              mixin("t."~a~"."~b.text.replace(".","_")~".add(del);");
            } else static if (is(c : connect!field, alias field)) {
              mixin("t."~field~".add(del);");
            }
          }
        }
        static if (i == "node") {
          node.applyStyles!(T, styles);
        } else static if (styles.length > 0) {
          static if (isCallable!(sym)) {
            alias params = ParameterIdentifierTuple!sym;
            auto args = getMemberTuple!(T,params)(t);
            if (__traits(getMember, t, i)(args.expand) == true) {
              node.applyStyles!(T, styles);
            }
          } else static if (is(typeof(sym) == bool)) {
            if (__traits(getMember, t, i) == true)
              node.applyStyles!(T, styles);
          } else static if (hasUDA!(sym, child)) {
            __traits(getMember, t, i).node.applyStyles!(typeof(sym), styles);
          }
        }
      }}
    static if (hasMember!(T, "node")) {
      t.node.node = node;
    }
  }
}


template among(alias field, T...) {
  static if (T.length == 0)
    enum among = false;
  else static if (T.length == 1)
    enum among = field.stringof == T[0];
  else
    enum among = among!(field,T[0..$/2]) || among!(field,T[$/2..$]);
}

template updateChildren(string field) {
  static auto updateChildren(Parent, Ts...)(auto ref Parent parent, auto ref Ts ts) {
    import std.traits : getSymbolsByUDA;
    import std.meta : ApplyLeft, staticMap;
    alias getSymbol = ApplyLeft!(getMember, parent);
    alias childrenNames = getChildren!Parent;
    alias children = staticMap!(getSymbol,childrenNames);
    static foreach(c; children) {{
      alias ChildType = typeof(c);
      static if (hasMember!(ChildType, field)) {
        __traits(getMember, parent, c.stringof).update!(__traits(getMember, __traits(getMember, parent, c.stringof), field));
      } else
        .updateChildren!(field)(__traits(getMember, parent, c.stringof));
      }}
  }
}

void update(Range, Sink)(Range source, ref Sink sink) {
  import std.range : ElementType;
  import std.algorithm : copy;
  alias E = ElementType!Range;
  auto output = Updater!(Sink)(&sink);
  foreach(i; source)
    output.put(i);
}

auto setVisible(string field, Parent)(auto ref Parent parent, bool visible) {
  bool current = __traits(getMember, parent, field).node.mounted;
  if (current != visible) {
    if (visible) {
      remount!(field)(parent);
    } else {
      unmount(__traits(getMember, parent, field));
    }
  }
}

template update(alias field) {
  static auto updateDom(Parent, T)(auto ref Parent parent, T t) {
    import std.traits : hasUDA, ParameterIdentifierTuple, isCallable, getUDAs;
    import std.typecons : AliasSeq;
    import std.meta : staticMap;
    alias name = domName!(field.stringof);
    static if (hasUDA!(field, prop)) {
      parent.node.setPropertyTyped!name(t);
    } else static if (hasUDA!(field, attr)) {
      parent.node.setAttributeTyped!name(t);
    }
    static if (is(T == bool)) {
      alias styles = getStyles!(field);
      static foreach(style; styles) {
        static string className = GetCssClassName!(Parent, style);
        parent.node.changeClass(className,t);
      }
    }
    static foreach(i; __traits(allMembers, Parent)) {{
        alias sym = AliasSeq!(__traits(getMember, parent, i))[0];
        static if (isCallable!(sym)) {
          alias params = ParameterIdentifierTuple!sym;
          static if (among!(field, params)) {
            auto args = getMemberTuple!(Parent,params)(parent);
            static if (hasUDA!(sym, prop)) {
              alias cleanName = domName!i;
              parent.node.node.setPropertyTyped!cleanName(__traits(getMember, parent, i)(args.expand));
            }
            else static if (hasUDA!(sym, style)) {
              alias styles = getStyles!(sym);
              static foreach(style; styles) {
                static string className = GetCssClassName!(Parent, style);
                parent.node.node.changeClass(className,__traits(getMember, parent, i)(args.expand));
              }
            } else {
              import std.traits : ReturnType;
              alias RType = ReturnType!(__traits(getMember, parent, i));
              static if (is(RType : void))
                __traits(getMember, parent, i)(args.expand);
              else {
                auto result = __traits(getMember, parent, i)(args.expand);
                static if (hasUDA!(sym, visible)) {
                  alias udas = getUDAs!(sym, visible);
                  static foreach(uda; udas) {
                    static if (is(uda : visible!elem, alias elem)) {
                      setVisible!(elem)(parent, result);
                    }
                  }
                }
              }
            }
          }
        }
      }}
    updateChildren!(field.stringof)(parent);
  }
  static auto update(Parent)(auto ref Parent parent) {
    updateDom(parent, __traits(getMember, parent, field.stringof));
  }
  static auto update(Parent, T)(auto ref Parent parent, T t) {
    mixin("parent."~field.stringof~" = t;");
    updateDom(parent, t);
  }
}

void setPointerFromParent(string name, T, Ts...)(ref T t, auto ref Ts ts) {
  import std.traits : PointerTarget;
  import std.meta : AliasSeq;
  alias FieldType = PointerTarget!(typeof(getMember!(T, name)));
  template matchesField(Parent) {
    enum matchesField = hasMember!(Parent, name) && is(typeof(getMember!(Parent, name)) == FieldType);
  }
  enum index = indexOfPred!(matchesField, AliasSeq!Ts);
  __traits(getMember, t, name) = &__traits(getMember, ts[index], name);
}

auto setAttributeTyped(string name, T)(JsHandle node, auto ref T t) {
  import std.traits : isPointer;
  static if (isPointer!T)
    node.setAttributeTyped!name(*t);
  else static if (is(T == bool))
    node.setAttributeBool(name, t);
  else {
    node.setAttribute(name, t);
  }
}

auto setPropertyTyped(string name, T)(JsHandle node, auto ref T t) {
  import std.traits : isPointer;
  static if (isPointer!T) {
    node.setPropertyTyped!name(*t);
  }
  else static if (is(T == bool))
    node.setPropertyBool(name, t);
  else {
    static if (__traits(compiles, __traits(getMember, api, name)))
      __traits(getMember, api, name)(node, t);
    else
      node.setProperty(name, t);
  }
}

auto applyStyles(T, styles...)(JsHandle node) {
  static foreach(style; styles) {
    node.addClass(GetCssClassName!(T, style));
  }
}

JsHandle createNode(T)(JsHandle parent, ref T t) {
  enum hasNode = hasMember!(T, "node");
  static if (hasNode) {
    static if (is(typeof(t.node) : NamedJsHandle!tag, alias tag)) {
      mixin("NodeType n = NodeType."~tag~";");
      return createElement(n);
    } else
      static assert("node field is invalid type");
  }
  return parent;
}

template indexOfPred(alias Pred, TList...) {
  enum indexOfPred = indexOf!(Pred, TList).index;
}

template indexOf(alias Pred, args...) {
  import std.meta : AliasSeq;
  static if (args.length > 0) {
    static if (Pred!(args[0])) {
      enum index = 0;
    } else {
      enum next  = indexOf!(Pred, AliasSeq!(args[1..$])).index;
      enum index = (next == -1) ? -1 : 1 + next;
    }
  } else {
    enum index = -1;
  }
}

template domName(string name) {
  import std.algorithm : stripRight;
  enum domName = name.stripRight('_');
}

auto getMemberTuple(Member, T...)(Member member) {
  import std.algorithm : joiner;
  import std.conv : text;
  import std.meta : staticMap;
  import std.range : only;
  import std.typecons : tuple;
  // TODO: this fails when s == an UFCS function...
  template addMember(alias s) { enum addMember = "member."~s; }
  alias list = staticMap!(addMember, T);
  return mixin("tuple("~list.only.joiner(",").text~")");
}

