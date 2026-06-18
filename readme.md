Idk.

## Example Program
```jai
#import,file "../Ecs.jai";
#import "Basic";

// a component
Transform :: struct {
   position:   [3] float;
   rotation:   [4] float;
   scale:      [3] float;
}

main :: () {
   registry: Ecs(u64); // u64 is the entity type.

   // create an entity. in real programs, you may generate a random number, or find another way to generate entity ids. idk.
   entity: u64 = 69;

   AddComponent(*registry, entity, Transform.{});

   transform := GetComponent(*registry, entity, Transform);
   transform.position = .[69, 4, 20];

   query := Query(*registry, Transform);
   for query.entities {
      t := GetComponent(*registry, it, Transform);
      print("[%] t: %\n", it, t.*);
   }

   // Foreach is not so useful because there are no closures.
   Foreach(*registry, Transform, (e, t) => ifx true {
      print("Foreach: [%] t: %\n", e, t.*);
      false;
   });
}
```