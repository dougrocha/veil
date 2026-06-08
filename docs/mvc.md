# Model, View, Projection matrices

## Model matrix

Model matrix holds the vertices relative to the objects center.

The objects center is at (0,0,0)

## View matrix

Instead of moving the world to view a different angle you move the camera.

This introduces another matrix which pretty much translates everything in the world
in the opposite direction of where the camera is.

## Projection matrix

This helps the viewport understand where objects are. For example two vertex can share (0,0) so we need
to know the z index of where they are too. To understand where to draw them.

## Diagram

Model coordinates -> (model matrix) -> World Coordinates 

World Coordinates-> (view matrix) -> Camera coordinates

Camera coordinates -> (projection matrix) -> Homogeneous Coordinates


## Some math

```c
// in CPU, compute
glm::mat4 MPVmatrix = projection * view * model;

// GLSL: apply it
transformed_vertex = MPV * inVertex;
```

```c
// projection matrix
// 45 degree field of view, 4:3 ratio, display range: 0.1 unit <-> 100 units
glm::mat4 proj = glm::perspective(glm::radians(45.0f), (float) width / (float) height, 0.1f, 100.0f)

glm::mat4 view = glm::lookAt(
  glm::vec3(4,3,3), // Camera is at this position, in world space
  glm::vec3(0,0,0), // and looks at the origin
  glm::vec3(0,1,0), // head is up, is (0,-1,0) we would be upside down
);

// Model matrix is just an identity matrix (model will be at origin)
glm::mat4 model = glm::mat4(1.0f);

// Our MVP is a result of this computation; order matters
glm::mat4 mpv = projection * view * model;
```
