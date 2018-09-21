module spa.node;

import spa.types;

template getChildren(Parent) {
  import std.traits : hasUDA;
  import std.meta : AliasSeq;
  alias members = AliasSeq!(__traits(allMembers, Parent));
  template isChild(string member) {
    static if (__traits(compiles, __traits(getMember, Parent, member)))
      enum isChild = hasUDA!(__traits(getMember, Parent, member), child);
    else
      enum isChild = false;
  }
  import std.meta : Filter;
  alias getChildren = Filter!(isChild, members);
}

struct NamedJsHandle(string tag) {
  import std.bitmanip : bitfields;
  JsHandle node = uint.max;
  mixin(bitfields!(bool, "mounted", 1,
                   bool, "marked",  1,
                   uint, "",        6));
  alias node this;
}

mixin template Node(string str) {
  mixin("NamedJsHandle!\""~str~"\" node;");
}
