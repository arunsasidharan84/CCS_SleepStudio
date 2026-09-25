//! Reading back our own JSON outputs. `serde_json` writes `NaN` as `null`,
//! which a plain `f64` field then refuses to read; this deserializer maps
//! `null` to `NaN` wherever a float is expected (and to `None` for options),
//! so cached result files can be reused by `--skip-existing`.

use serde::de::{self, DeserializeOwned, DeserializeSeed, IntoDeserializer, MapAccess, SeqAccess, Visitor};
use serde::forward_to_deserialize_any;
use serde_json::Value;
use std::path::Path;

pub fn from_path<T: DeserializeOwned>(path: &Path) -> anyhow::Result<T> {
    let file = std::fs::File::open(path)?;
    let value: Value = serde_json::from_reader(std::io::BufReader::new(file))?;
    Ok(T::deserialize(NanDe(value))?)
}

pub fn from_str<T: DeserializeOwned>(text: &str) -> anyhow::Result<T> {
    let value: Value = serde_json::from_str(text)?;
    Ok(T::deserialize(NanDe(value))?)
}

struct NanDe(Value);

struct Seq(std::vec::IntoIter<Value>);

impl<'de> SeqAccess<'de> for Seq {
    type Error = serde_json::Error;
    fn next_element_seed<S: DeserializeSeed<'de>>(&mut self, seed: S) -> Result<Option<S::Value>, Self::Error> {
        match self.0.next() {
            Some(v) => seed.deserialize(NanDe(v)).map(Some),
            None => Ok(None),
        }
    }
}

struct Map {
    iter: serde_json::map::IntoIter,
    value: Option<Value>,
}

impl<'de> MapAccess<'de> for Map {
    type Error = serde_json::Error;
    fn next_key_seed<K: DeserializeSeed<'de>>(&mut self, seed: K) -> Result<Option<K::Value>, Self::Error> {
        match self.iter.next() {
            Some((k, v)) => {
                self.value = Some(v);
                let key: de::value::StringDeserializer<serde_json::Error> = k.into_deserializer();
                seed.deserialize(key).map(Some)
            }
            None => Ok(None),
        }
    }
    fn next_value_seed<V: DeserializeSeed<'de>>(&mut self, seed: V) -> Result<V::Value, Self::Error> {
        let v = self.value.take().unwrap_or(Value::Null);
        seed.deserialize(NanDe(v))
    }
}

impl<'de> de::Deserializer<'de> for NanDe {
    type Error = serde_json::Error;

    fn deserialize_any<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Self::Error> {
        match self.0 {
            Value::Array(a) => visitor.visit_seq(Seq(a.into_iter())),
            Value::Object(m) => visitor.visit_map(Map { iter: m.into_iter(), value: None }),
            other => de::Deserializer::deserialize_any(other, visitor),
        }
    }

    fn deserialize_f64<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Self::Error> {
        match self.0 {
            Value::Null => visitor.visit_f64(f64::NAN),
            other => de::Deserializer::deserialize_f64(other, visitor),
        }
    }

    fn deserialize_f32<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Self::Error> {
        match self.0 {
            Value::Null => visitor.visit_f32(f32::NAN),
            other => de::Deserializer::deserialize_f32(other, visitor),
        }
    }

    fn deserialize_option<V: Visitor<'de>>(self, visitor: V) -> Result<V::Value, Self::Error> {
        match self.0 {
            Value::Null => visitor.visit_none(),
            other => visitor.visit_some(NanDe(other)),
        }
    }

    fn deserialize_newtype_struct<V: Visitor<'de>>(self, _name: &'static str, visitor: V) -> Result<V::Value, Self::Error> {
        visitor.visit_newtype_struct(self)
    }

    fn deserialize_enum<V: Visitor<'de>>(
        self,
        name: &'static str,
        variants: &'static [&'static str],
        visitor: V,
    ) -> Result<V::Value, Self::Error> {
        de::Deserializer::deserialize_enum(self.0, name, variants, visitor)
    }

    forward_to_deserialize_any! {
        bool i8 i16 i32 i64 i128 u8 u16 u32 u64 u128 char str string
        bytes byte_buf unit unit_struct seq tuple
        tuple_struct map struct identifier ignored_any
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    #[derive(serde::Deserialize, Debug)]
    struct S {
        a: f64,
        b: Option<f64>,
        m: BTreeMap<String, BTreeMap<String, f64>>,
        v: Vec<f64>,
        n: usize,
    }

    #[test]
    fn nulls_become_nan() {
        let s: S = from_str(r#"{"a":null,"b":null,"m":{"x":{"y":null,"z":1.5}},"v":[1,null],"n":3}"#).unwrap();
        assert!(s.a.is_nan());
        assert!(s.b.is_none());
        assert!(s.m["x"]["y"].is_nan());
        assert_eq!(s.m["x"]["z"], 1.5);
        assert!(s.v[1].is_nan());
        assert_eq!(s.n, 3);
    }
}
