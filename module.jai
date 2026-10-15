#import "Basic";
#import "Hash";
#import "Hash_Table";
#import "Sort";

//
// this ecs only works with types that comes from the same workspace that this file compiled in
// because it uses Type (*Type_Info). if you are getting components from a dll then this won't work.
//          - apila, 13/06/26
//

INVALID_INDEX :: -1;

ComponentStorage :: struct(TEntity: Type) {
   componentSize:    int;
   entities:         [..] TEntity;
   componentData:    [..] u8;
   sparse:           Table(TEntity, int);
}

Ecs :: struct(TEntity: Type) {
   storages:            Table(Type, ComponentStorage(TEntity), TypeHash, TypeEquals);
   entityComponents:    Table(TEntity, Table(Type, struct {}, TypeHash, TypeEquals));
   version:             int;
   queryCache:          Table(QueryCacheKey, QueryResult(TEntity), QueryCacheKeyHash, QueryCacheKeyEquals); // query components to query result
}

QueryResult :: struct(TEntity: Type) {
   entities:   [..] TEntity;
   version:    int;
}

QueryCacheKey :: [] Type; // sorted in the value of the pointer. Type == *Type_Info

DestroyEcs :: (ecs: *Ecs($TEntity)) {
   for *storage: ecs.storages {
      DestroyStorage(storage);
   }

   for components: ecs.entityComponents {
      deinit(components);
   }

   deinit(*ecs.storages);
   deinit(*ecs.entityComponents);
   ecs.* = .{};
}

RegisterComponent :: (ecs: *Ecs($TEntity), $TComponent: Type) {
   storage := table_find_pointer(*ecs.storages, TComponent);
   if storage return;

   newStorage: ComponentStorage(TEntity);
   newStorage.componentSize = size_of(TComponent);
   table_add(*ecs.storages, TComponent, newStorage);
}

AddComponent :: (ecs: *Ecs($TEntity), entity: TEntity, component: $TComponent) {
   added := TryAddComponent(ecs, entity, component);
   assert(added);
}

TryAddComponent :: (ecs: *Ecs($TEntity), entity: TEntity, component: $TComponent) -> bool {
   storage := EnsureStorage(ecs, TComponent);
   if StorageContains(storage, entity) return false;

   StorageAppend(storage, entity, *component);
   AddEntityToComponentMap(ecs, entity, TComponent);
   ecs.version += 1;
   return true;
}

SetComponent :: (ecs: *Ecs($TEntity), entity: TEntity, component: $TComponent) {
   storage := EnsureStorage(ecs, TComponent);

   found, index := StorageFindIndex(storage, entity);
   if found {
      destination := StorageComponentPointer(storage, index);
      memcpy(destination, *component, storage.componentSize);
      return;
   }

   StorageAppend(storage, entity, *component);
   AddEntityToComponentMap(ecs, entity, TComponent);
   ecs.version += 1;
}

GetComponent :: (ecs: *Ecs($TEntity), entity: TEntity, $TComponent: Type) -> *TComponent {
   storage := EnsureStorage(ecs, TComponent);
   rawComponent := StorageGet(storage, entity);
   return cast(*TComponent) rawComponent;
}

TryGetComponent :: (ecs: *Ecs($TEntity), entity: TEntity, $TComponent: Type) -> (success: bool, component: *TComponent) {
   storage := EnsureStorage(ecs, TComponent);

   success, rawComponent := StorageTryGet(storage, entity);
   return success, cast(*TComponent) rawComponent;
}

HasComponent :: (ecs: *Ecs($TEntity), entity: TEntity, $TComponent: Type) -> bool {
   storage := table_find_pointer(*ecs.storages, TComponent);
   if !storage return false;

   return StorageContains(storage, entity);
}

RemoveComponent :: (ecs: *Ecs($TEntity), entity: TEntity, $TComponent: Type) -> bool {
   storage := table_find_pointer(*ecs.storages, TComponent);
   if !storage return false;

   removed := StorageRemove(storage, entity);
   if removed {
      RemoveComponentFromEntityMap(ecs, entity, TComponent);
      ecs.version += 1;
   }

   return removed;
}

AddEntity :: (ecs: *Ecs($TEntity), entity: TEntity) -> bool {
   if (HasEntity(*ecs, entity)) return false;

   empty: [..] Type;
   table_add(*ecs.entityComponents, entity, empty);
   return true;
}

HasEntity :: (ecs: *Ecs($TEntity), entity: TEntity) -> bool {
   return table_contains(*ecs.entityComponents, entity);
}

RemoveEntity :: (ecs: *Ecs($TEntity), entity: TEntity) -> bool {
   components := table_find_pointer(*ecs.entityComponents, entity);
   if !components return false;

   for _, componentType: components.* {
      storage := table_find_pointer(*ecs.storages, componentType);
      if storage StorageRemove(storage, entity);
   }

   deinit(components);
   table_remove(*ecs.entityComponents, entity);
   ecs.version += 1;
   return true;
}

GetComponentTypes :: (ecs: *Ecs($TEntity), entity: TEntity) -> [] Type {
   components := table_find_pointer(*ecs.entityComponents, entity);
   assert(components != null);

   result := NewArray(components.count, Type);
   index := 0;
   for value, key: components.* {
      result[index] = key;
      index += 1;
   }

   return result;
}

GetComponentCount :: (ecs: *Ecs($TEntity), $TComponent: Type) -> int {
   storage := table_find_pointer(*ecs.storages, TComponent);
   if !storage return 0;

   return storage.entities.count;
}

Query :: (ecs: *Ecs($TEntity), componentTypes: ..Type) -> QueryResult(TEntity) {
   assert(componentTypes.count > 0);

   qck := CreateQueryCacheKeyFromArray(componentTypes,, temp);
   cachedResult := table_find_pointer(*ecs.queryCache, qck);
   if (cachedResult != null && cachedResult.version == ecs.version) {
      return cachedResult;
   }

   result: QueryResult(TEntity);
   result.version = ecs.version;

   smallestStorage: *ComponentStorage(TEntity);
   smallestCount := 0;
   smallestComponentType: Type;

   for componentType: componentTypes {
      storage := table_find_pointer(*ecs.storages, componentType);
      if !storage return result;

      if !smallestStorage || storage.entities.count < smallestCount {
         smallestStorage = storage;
         smallestCount = storage.entities.count;
         smallestComponentType = componentType;
      }
   }

   for entity: smallestStorage.entities {
      hasAll := true;

      for componentType: componentTypes {
         if componentType == smallestComponentType continue;

         storage := table_find_pointer(*ecs.storages, componentType);
         if !storage || !StorageContains(storage, entity) {
            hasAll = false;
            break;
         }
      }

      if hasAll array_add(*result.entities, entity);
   }

   table_set(*ecs.queryCache, qck, result);
   return result;
}

DestroyQueryResult :: (queryResult: *QueryResult($TEntity)) {
   array_free(queryResult.entities);
   queryResult.* = .{};
}

IsQueryResultValid :: (ecs: *Ecs($TEntity), queryResult: QueryResult(TEntity)) -> bool {
   return queryResult.version == ecs.version;
}

Foreach :: (ecs: *Ecs($TEntity), $T0: Type, callback: (TEntity, *T0) -> bool) {
   storage := table_find_pointer(*ecs.storages, T0);
   if !storage return;

   componentCount := GetComponentCount(ecs, T0);
   for 0..componentCount - 1 {
      component := cast(*T0) StorageComponentPointer(storage, it);
      entity := storage.entities[it];
      if callback(entity, component) break;
   }
}

Foreach :: (ecs: *Ecs($TEntity), $T0: Type, $T1: Type, callback: (TEntity, *T0, *T1) -> bool) {
   queryResult := Query(ecs, T0, T1);

   for entity: queryResult.entities {
      c0 := GetComponent(ecs, entity, T0);
      c1 := GetComponent(ecs, entity, T1);
      if callback(entity, c0, c1) break;
   }
}

Foreach :: (ecs: *Ecs($TEntity), $T0: Type, $T1: Type, $T2: Type, callback: (TEntity, *T0, *T1, *T2) -> bool) {
   queryResult := Query(ecs, T0, T1, T2);

   for entity: queryResult.entities {
      c0 := GetComponent(ecs, entity, T0);
      c1 := GetComponent(ecs, entity, T1);
      c2 := GetComponent(ecs, entity, T2);
      if callback(entity, c0, c1, c2) break;
   }
}

Foreach :: (ecs: *Ecs($TEntity), $T0: Type, $T1: Type, $T2: Type, $T3: Type, callback: (TEntity, *T0, *T1, *T2, *T3) -> bool) {
   queryResult := Query(ecs, T0, T1, T2, T3);

   for entity: queryResult.entities {
      c0 := GetComponent(ecs, entity, T0);
      c1 := GetComponent(ecs, entity, T1);
      c2 := GetComponent(ecs, entity, T2);
      c3 := GetComponent(ecs, entity, T3);
      if callback(entity, c0, c1, c2, c3) break;
   }
}

#scope_file

EnsureStorage :: (ecs: *Ecs($TEntity), $TComponent: Type) -> *ComponentStorage(TEntity) {
   storage := table_find_pointer(*ecs.storages, TComponent);
   if storage return storage;

   RegisterComponent(ecs, TComponent);
   storage = table_find_pointer(*ecs.storages, TComponent);
   assert(storage != null);
   return storage;
}

DestroyStorage :: (storage: *ComponentStorage($TEntity)) {
   array_free(storage.entities);
   array_free(storage.componentData);
   deinit(*storage.sparse);
   storage.* = .{};
}

StorageFindIndex :: (storage: *ComponentStorage($TEntity), entity: TEntity) -> (success: bool, index: int) {
   index := table_find_pointer(*storage.sparse, entity);
   if index return true, index.*;

   return false, INVALID_INDEX;
}

StorageContains :: (storage: *ComponentStorage($TEntity), entity: TEntity) -> bool {
   return table_contains(*storage.sparse, entity);
}

StorageAppend :: (storage: *ComponentStorage($TEntity), entity: TEntity, component: *void) {
   index := storage.entities.count;

   array_add(*storage.entities, entity);
   EnsureComponentDataSpace(storage, index + 1);

   destination := StorageComponentPointer(storage, index);
   memcpy(destination, component, storage.componentSize);

   table_add(*storage.sparse, entity, index);
}

StorageGet :: (storage: *ComponentStorage($TEntity), entity: TEntity) -> *void {
   found, index := StorageFindIndex(storage, entity);
   assert(found);

   return StorageComponentPointer(storage, index);
}

StorageTryGet :: (storage: *ComponentStorage($TEntity), entity: TEntity) -> (success: bool, component: *void) {
   found, index := StorageFindIndex(storage, entity);
   if !found return false, null;

   return true, StorageComponentPointer(storage, index);
}

StorageRemove :: (storage: *ComponentStorage($TEntity), entity: TEntity) -> bool {
   found, index := StorageFindIndex(storage, entity);
   if !found return false;

   lastIndex := storage.entities.count - 1;

   if index != lastIndex {
      movedEntity := storage.entities[lastIndex];
      storage.entities[index] = movedEntity;

      destination := StorageComponentPointer(storage, index);
      source := StorageComponentPointer(storage, lastIndex);
      memcpy(destination, source, storage.componentSize);

      movedIndex := table_find_pointer(*storage.sparse, movedEntity);
      assert(movedIndex != null);
      movedIndex.* = index;
   }

   storage.entities.count -= 1;
   storage.componentData.count -= storage.componentSize;
   table_remove(*storage.sparse, entity);

   return true;
}

EnsureComponentDataSpace :: (storage: *ComponentStorage($TEntity), componentCount: int) {
   requiredByteCount := componentCount * storage.componentSize;
   array_reserve(*storage.componentData, requiredByteCount);
   storage.componentData.count = requiredByteCount;
}

StorageComponentPointer :: (storage: *ComponentStorage($TEntity), index: int) -> *void {
   assert(index >= 0);
   assert(index < storage.entities.count);

   byteIndex := index * storage.componentSize;
   return storage.componentData.data + byteIndex;
}

AddEntityToComponentMap :: (ecs: *Ecs($TEntity), entity: TEntity, componentType: Type) {
   components := find_or_add(*ecs.entityComponents, entity);
   find_or_add(components, componentType);
}

RemoveComponentFromEntityMap :: (ecs: *Ecs($TEntity), entity: TEntity, componentType: Type) {
   components := table_find_pointer(*ecs.entityComponents, entity);
   if !components return;

   table_remove(components, componentType);
}

TypeHash :: (type: Type) -> u32 {
   return get_hash(cast(*Type_Info) type);
}

TypeEquals :: (a: Type, b: Type) -> bool {
   return a == b;
}

QueryCacheKeyHash :: (qck: QueryCacheKey) -> u32 {
   return get_hash(qck);
}

QueryCacheKeyEquals :: (a: QueryCacheKey, b: QueryCacheKey) -> bool {
   if (a.count != b.count) return false;

   for a {
      if (it != b[it_index]) return false;
   }

   return true;
}

CreateQueryCacheKeyFromArray :: (types: [] Type) -> QueryCacheKey {
   result := NewArray(types.count, Type);
   memcpy(result.data, types.data, types.count * size_of(type_of(types[0])));
   quick_sort(result, type => cast(u64) cast(*Type_Info) type);
   return result;
}
